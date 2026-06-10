import CoreGraphics
import MetalKit
import os
import simd
#if canImport(MetalFX)
// Absent du SDK simulateur : tout le chemin MetalFX est compilé conditionnellement,
// le repli bilinéaire (chemin historique) est le seul code sur simulateur.
import MetalFX
#endif

/// Une coquille concentrique prête pour le GPU (modèle multi-coquilles, étape 4).
/// Disposition mémoire **identique** à `Shell` dans `Cloud.metal` (deux float4 +
/// quatre `uint`, le tout aligné sur 16 octets).
private struct ShellGPU {
    var radii: SIMD4<Float>   // x: inner ; y: outer ; z: cloudType ; w: noiseScale
    var drift: SIMD4<Float>   // xy: dérive bruit ; z: coverageBias ; w: opacity
    var layerSlice: UInt32    // tranche de la coquille dans l'atlas de couverture
    var visible: UInt32       // 1 si le calque est visible, 0 pour l'ignorer
    var pad0: UInt32 = 0      // bourrage : garde la struct alignée sur 16 octets
    var pad1: UInt32 = 0

    /// Coquille vide (ignorée à la marche) : rembourrage de l'atlas de coquilles.
    static let empty = ShellGPU(radii: .zero, drift: .zero, layerSlice: 0, visible: 0)
}

/// Tableau de taille fixe de `CloudLayer.maxCount` (= 4) coquilles GPU, à
/// disposition mémoire contiguë (équivalent de `Shell shells[kMaxShells]` dans
/// `Cloud.metal`). Un `struct` plutôt qu'un tuple à 4 membres (lisibilité + règle
/// SwiftLint `large_tuple`).
private struct ShellQuad {
    var shell0 = ShellGPU.empty
    var shell1 = ShellGPU.empty
    var shell2 = ShellGPU.empty
    var shell3 = ShellGPU.empty

    /// Construit le quad depuis les coquilles triées (au plus 4 ; le reste reste
    /// vide). Les coquilles au-delà de `layerCount` ne sont jamais lues côté GPU.
    init(_ shells: [ShellGPU]) {
        if shells.indices.contains(0) { shell0 = shells[0] }
        if shells.indices.contains(1) { shell1 = shells[1] }
        if shells.indices.contains(2) { shell2 = shells[2] }
        if shells.indices.contains(3) { shell3 = shells[3] }
    }
}

/// Uniforms du shader de nuage. La disposition mémoire doit correspondre à
/// `CloudUniforms` dans `Cloud.metal`. Modèle multi-coquilles (étape 4) : la forme
/// vient de la couverture directionnelle peinte (atlas 2D array) et de
/// l'empilement de coquilles concentriques, plus de cubes.
private struct CloudUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var aspect: Float
    var sunDirection: SIMD4<Float>
    var camera: SIMD4<Float>  // x: tan(FOV vertical / 2)
    var lightSun: SIMD4<Float>
    var lightAmbient: SIMD4<Float>
    // Base caméra → monde du regard (lacet + tangage), pour le rayon de vue.
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
    var camForward: SIMD4<Float>
    // Coquilles concentriques à marcher, triées par rayon `inner` croissant (la
    // plus basse en premier → front-to-back). `layerCount` borne la boucle.
    // Tableau de taille fixe `CloudLayer.maxCount` (= `kMaxShells` côté shader).
    var shells: ShellQuad
    var layerCount: UInt32
}

/// Amortissement temporel (étape 7). Doit correspondre à `CloudTemporal` dans
/// `Cloud.metal`.
private struct CloudTemporal {
    var activeIndex: UInt32
    var stride: UInt32  // 2 au repos (¼ des pixels, cellule active), 1 en mouvement
}

/// Uniforms du shader de ciel atmosphérique. Disposition mémoire **identique**
/// à `SkyUniforms` dans `Background.metal`.
private struct SkyUniforms {
    var sunDirection: SIMD4<Float>        // xyz: direction monde vers le soleil
    var rayleighScattering: SIMD4<Float>  // xyz: Rayleigh ; w: Mie
    var scaleHeights: SIMD4<Float>        // x: H Rayleigh ; y: H Mie ; z: g ; w: intensité soleil
    var radii: SIMD4<Float>               // x: rayon planète ; y: atmosphère ; z: œil ; w: exposition
    var camera: SIMD4<Float>              // x: tan(FOV/2) ; y: aspect ; z: éclairement sol
    // Base caméra → monde (lacet + tangage) : oriente le rayon de vue du ciel.
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
    var camForward: SIMD4<Float>
    // Mer sous l'horizon (technique « Seascape » / TDM).
    var sea0: SIMD4<Float>    // x: activée (0/1) ; y: niveau ; z: amplitude ; w: hachure
    var sea1: SIMD4<Float>    // x: fréquence ; y: vitesse ; z: temps ; w: inutilisé
    var seaBase: SIMD4<Float> // xyz: couleur eau profonde
    var seaWater: SIMD4<Float> // xyz: teinte diffuse de l'eau
    var moonDirection: SIMD4<Float> // xyz: direction monde de la lune ; w: poids nocturne
    var moonGlint: SIMD4<Float>     // xyz: couleur du clair de lune (intensité comprise)
    var skyZenith: SIMD4<Float>     // xyz: radiance ciel au zénith (intégrale CPU, linéaire)
    var skyHorizon: SIMD4<Float>    // xyz: radiance ciel à l'horizon (intégrale CPU, linéaire)
    // Disques soleil/lune dessinés dans le ciel (la lune réutilise `moonDirection`).
    var discParams: SIMD4<Float>     // x: rayon angulaire soleil ; y: lune ; z/w: inutilisés
    var sunDiscColor: SIMD4<Float>   // xyz: couleur du disque solaire (nulle sous l'horizon)
    var moonDiscColor: SIMD4<Float>  // xyz: blanc froid lunaire, atténué par l'altitude
}

/// Une étoile prête pour le GPU. Disposition **identique** à `GPUStar` dans
/// `Stars.metal` (deux float4).
private struct GPUStar {
    var dirMag: SIMD4<Float>  // xyz: direction monde ; w: magnitude visuelle
    var extra: SIMD4<Float>   // x: indice B-V ; yzw: inutilisés
}

/// Uniforms par frame du shader d'étoiles. Disposition **identique** à
/// `StarUniforms` dans `Stars.metal`.
private struct StarUniforms {
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
    var camForward: SIMD4<Float>
    var params: SIMD4<Float>  // x: tan(FOV/2) ; y: aspect ; z: poids nocturne ; w: temps (s)
}

/// Uniforms du shader de god rays (rayons crépusculaires). Disposition
/// **identique** à `GodRayUniforms` dans `GodRays.metal`.
private struct GodRayUniforms {
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
    var camForward: SIMD4<Float>
    var camera: SIMD4<Float>        // x: tan(FOV/2) ; y: aspect
    var sunDirection: SIMD4<Float>  // xyz: direction monde vers le soleil
    var sunColor: SIMD4<Float>      // xyz: couleur du disque solaire (nulle sous l'horizon)
    var params: SIMD4<Float>        // x: densité ; y: décroissance ; z: poids ; w: intensité
}

/// Rendu du modèle multi-coquilles (cf. `docs/SHELLS.md`) : le paysage en
/// texture de fond, surmonté de nuages dont la forme provient de **coquilles
/// sphériques concentriques** peintes en couverture directionnelle (atlas 2D
/// par calque). Le bruit Perlin-Worley en détaille la densité ; l'empilement des
/// coquilles crée les étages (cumulus bas … cirrus haut).
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let skyPipeline: MTLRenderPipelineState
    private let skyRadiancePipeline: MTLComputePipelineState
    private let cloudPipeline: MTLComputePipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let starPipeline: MTLRenderPipelineState
    // God rays : passe demi-rés (rayons crépusculaires) + composition additive.
    private let godRaysPipeline: MTLRenderPipelineState
    private let godRaysCompositePipeline: MTLRenderPipelineState
    // Couverture directionnelle (modèle multi-coquilles, cf. `docs/SHELLS.md` §5) :
    // cuit les traits des calques dans un atlas équirectangulaire 2D par calque,
    // échantillonné par le raymarch concentrique.
    private let coverageBaker: CoverageBaker
    // Paysage : placeholder au départ, remplacé par la Feature (galerie curée)
    // via `setLandscape`.
    private var landscapeTexture: MTLTexture
    private let noiseTexture: MTLTexture
    private let sampler: MTLSamplerState
    private let startTime = CACurrentMediaTime()
    private let log = Logger(subsystem: "io.github.glandais.aether", category: "Renderer")
    // Compteur d'images : moyenne le débit sur ~1 s et le journalise (os.log).
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsFrameCount = 0

    // Cible demi-résolution **persistante** du raymarch nuage amorti : le compute
    // kernel y réécrit la cellule active (¼ des pixels au repos), le reste garde
    // la valeur des frames précédentes. `cloudAccumDirty` force un refresh complet
    // après (ré)allocation pour ne pas composer du bruit non initialisé.
    private var cloudAccum: MTLTexture?
    private var cloudAccumDirty = true
    private var cloudTargetWidth = 0
    private var cloudTargetHeight = 0
    // Radiance du ciel amortie (même schéma que `cloudAccum`) : écrite par le
    // compute kernel, lue par la passe ciel+mer. La mer, animée, n'est pas amortie.
    private var skyAccum: MTLTexture?
    // Ciel + mer rendus hors écran à demi-résolution (HDR), upsamplés au composite.
    private var skyTarget: MTLTexture?
    // God rays (rayons crépusculaires) rendus hors écran à demi-rés, composés
    // additivement par-dessus tout au passage composite.
    private var godRayTarget: MTLTexture?

    #if canImport(MetalFX)
    // MetalFX : le composite est rendu **en demi-rés** (lectures 1:1 des cibles)
    // puis agrandi ×2 vers le drawable par le scaler spatial — unique étage
    // d'upscale du pipeline, à la place du bilinéaire plein écran (cf.
    // `docs/PIPELINE.md`). Absent du SDK simulateur → repli : composite
    // plein écran avec upsample bilinéaire (chemin historique).
    private let metalFXEnabled: Bool
    // Échelle interne du chemin MetalFX (½ = facteur d'upscale 2×, le maximum
    // recommandé pour le scaler spatial). Surchargée en DEBUG par `AETHER_SCALE`.
    private let internalScale: Float
    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerFailed = false
    private var compositeTarget: MTLTexture?
    private var upscaledTarget: MTLTexture?
    private var scalerOutputWidth = 0
    private var scalerOutputHeight = 0
    private let drawableFormat: MTLPixelFormat
    // Présentation du composite agrandi : copie opaque plein écran (réutilise
    // `composite_fragment`, sans blending).
    private let presentPipeline: MTLRenderPipelineState
    #endif

    private var frameIndex = 0
    // Ordre de Bayer 2×2 : répartit les 4 cellules sur 4 frames.
    private static let activeOrder: [UInt32] = [0, 3, 1, 2]

    // Direction du soleil (vers l'astre), résolue par la Feature depuis
    // l'`AstroService` (étape 8). Valeur de repli avant la première mise à jour.
    private var sunDirection = SIMD3<Float>(0.40, 0.12, -0.50)

    // Ciel atmosphérique : direction monde du soleil (distincte de la lumière du
    // nuage, qui passe à la lune la nuit) + paramètres de diffusion.
    private var skySunDirection = SIMD3<Float>(0.40, 0.12, -0.50)
    private var atmosphere = Atmosphere.earth
    // Niveau d'éclairement du sol (0 nuit → 1 jour) : assombrit le paysage sous
    // l'horizon avec le ciel.
    private var skyGroundLight: Float = 1
    // Exposition du tonemap ciel (à régler par capture).
    private static let skyExposure: Float = 1.0

    // Disques soleil/lune dessinés dans le ciel. Le soleil réutilise
    // `skySunDirection`, la lune `moonSkyDirection` ; les couleurs sont résolues
    // par la Feature (soleil = transmittance atmosphérique, nulle sous l'horizon ;
    // lune = blanc froid atténué par son altitude). Repli avant mise à jour.
    private var sunDiscColor = SIMD3<Float>.zero
    private var moonDiscColor = SIMD3<Float>.zero
    // Rayons angulaires (radians). Le vrai diamètre est ~0.0045 rad (0.5°) ;
    // légèrement agrandis (~2×) pour une présence lisible. Constants avec l'heure.
    private static let sunAngularRadius: Float = 0.009
    private static let moonAngularRadius: Float = 0.009

    // God rays (rayons crépusculaires) — registre sobre : effet subtil, à doser.
    // `density` = portée de la marche radiale vers le soleil ; `decay` = perte par
    // pas ; `weight` = contribution par échantillon ; `intensity` = échelle finale.
    private static let godRayDensity: Float = 0.6
    private static let godRayDecay: Float = 0.96
    private static let godRayWeight: Float = 0.04
    private static let godRayIntensity: Float = 0.5

    // Mer rendue sous l'horizon (`.none` = paysage terrestre). Résolue par la
    // Feature depuis le paysage curé.
    private var sea = SeaSurface.none

    // Lune (direction monde + clair de lune + poids nocturne) pour le reflet sur
    // la mer la nuit. Résolue par la Feature.
    private var moonSkyDirection = SIMD3<Float>(0, -1, 0)
    private var moonGlint = SIMD3<Float>(0, 0, 0)
    private var nightWeight: Float = 0

    #if DEBUG
    // Interrupteurs de passe (profilage perf) : désactivent une passe pour isoler
    // son coût en relançant avec la variable d'env, sans rebuild.
    private static let perfNoSky = ProcessInfo.processInfo.environment["AETHER_PERF_NOSKY"] == "1"
    private static let perfNoSea = ProcessInfo.processInfo.environment["AETHER_PERF_NOSEA"] == "1"
    private static let perfNoCloud = ProcessInfo.processInfo.environment["AETHER_PERF_NOCLOUD"] == "1"
    #if canImport(MetalFX)
    // Échelle interne forcée (profilage MetalFX) : `1` force le repli bilinéaire,
    // une valeur < 0.5 teste un facteur d'upscale > 2× (mesure seulement).
    private static let debugScale = ProcessInfo.processInfo.environment["AETHER_SCALE"]
        .flatMap(Float.init)
    #endif
    #endif

    // Étoiles (BSC5) dessinées dans le ciel — purs points additifs, sans
    // éclairage. Les directions monde sont résolues par la Feature pour le
    // lieu/heure (cf. `StarCatalog`) et téléversées dans `starBuffer` ; on ne
    // reconstruit le buffer que lorsque `starRevision` change (la rotation/zoom
    // ne change que la base caméra, appliquée côté GPU).
    private var starBuffer: MTLBuffer?
    private var starCount = 0
    private var appliedStarRevision = -1

    // Radiance du ciel (zénith / horizon) pour le reflet bon marché de la mer.
    private var skyZenithRadiance = SIMD3<Float>(0, 0, 0)
    private var skyHorizonRadiance = SIMD3<Float>(0, 0, 0)

    // tan(FOV vertical / 2) de la caméra de la scène (défaut ≈ 53°). Cale la
    // projection du ciel et le cadrage du volume sur le zoom de la photo.
    private var cameraTanHalfFov: Float = 0.5

    // Base caméra → monde du regard (lacet + tangage), résolue par la Feature.
    // Identité par défaut : caméra droite face au Nord (-Z).
    private var cameraRight = SIMD3<Float>(1, 0, 0)
    private var cameraUp = SIMD3<Float>(0, 1, 0)
    private var cameraForward = SIMD3<Float>(0, 0, -1)
    // Détection du mouvement du regard (rotation/zoom) d'une frame à l'autre :
    // désactive l'amortissement temporel tant que le regard bouge (sinon le
    // nuage persistant traîne au lieu de suivre le rayon). Repli identité.
    private var lastCameraForward = SIMD3<Float>(0, 0, -1)
    private var lastCameraTanHalfFov: Float = 0.5

    // Éclairage résolu par la Feature (couleur soleil par altitude × exposition
    // de la photo, et ambiance ciel). Valeurs de repli avant mise à jour.
    private var sunColor = SIMD3<Float>(6.5, 4.7, 3.4)
    private var skyAmbient = SIMD3<Float>(0.34, 0.40, 0.55)
    private static let cloudColorFormat: MTLPixelFormat = .rgba16Float

    // Calques à cuire en couverture, fournis par la Feature ; réconciliés au
    // début de `draw` via `coverageBaker`.
    private var pendingLayers: [CloudLayer] = []

    // Créé depuis `MetalView` (UIViewRepresentable, @MainActor) ; l'init touche
    // les propriétés main-actor de `MTKView` (device, colorPixelFormat).
    @MainActor
    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            // Pas de force-unwrap : sans device / bibliothèque Metal, pas de rendu.
            return nil
        }
        self.device = device
        view.device = device

        guard let backgroundVertex = library.makeFunction(name: "background_vertex"),
              let skyFragment = library.makeFunction(name: "sky_background_fragment"),
              let cloudKernel = library.makeFunction(name: "cloud_kernel"),
              let skyRadianceKernel = library.makeFunction(name: "sky_radiance_kernel"),
              let compositeVertex = library.makeFunction(name: "composite_vertex"),
              let compositeFragment = library.makeFunction(name: "composite_fragment"),
              let starVertex = library.makeFunction(name: "star_vertex"),
              let starFragment = library.makeFunction(name: "star_fragment"),
              let godRaysVertex = library.makeFunction(name: "god_rays_vertex"),
              let godRaysFragment = library.makeFunction(name: "god_rays_fragment") else {
            return nil
        }

        let format = view.colorPixelFormat

        #if canImport(MetalFX)
        // Décision MetalFX unique à l'init : scaler spatial supporté par le
        // device ? (Le simulateur n'a même pas le framework → repli compilé.)
        drawableFormat = format
        var metalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        var scale: Float = 0.5
        #if DEBUG
        if let forced = Renderer.debugScale {
            if forced >= 1.0 {
                metalFXSupported = false
            } else {
                scale = max(forced, 0.25)
            }
        }
        #endif
        metalFXEnabled = metalFXSupported
        internalScale = scale
        #endif

        do {
            // Ciel atmosphérique dynamique (suit le soleil). `background_vertex`
            // est le triangle plein écran partagé ; échantillonne le paysage
            // sous l'horizon. Rendu **hors écran à demi-résolution** (comme le
            // nuage) : la mer raymarchée y est coûteuse, l'upsample a lieu au
            // passage composite. D'où le format HDR `cloudColorFormat`.
            skyPipeline = try Renderer.makePipeline(
                device: device, vertex: backgroundVertex, fragment: skyFragment,
                pixelFormat: Renderer.cloudColorFormat, blend: .none)
            // Radiance atmosphérique du ciel : compute amorti (comme le nuage),
            // écrit `skyAccum` lu par la passe ciel+mer. La mer reste plein régime.
            skyRadiancePipeline = try device.makeComputePipelineState(function: skyRadianceKernel)
            // Le nuage est raymarché par un **compute kernel** dans une cible
            // persistante (demi-rés, HDR) : l'amortissement temporel écrit la
            // cellule active de façon compacte (¼ des pixels au repos), sans la
            // divergence SIMD d'un fragment plein écran qui sort tôt sur ¾ des
            // lignes. La composition « over » a lieu au passage composite.
            cloudPipeline = try device.makeComputePipelineState(function: cloudKernel)
            compositePipeline = try Renderer.makePipeline(
                device: device, vertex: compositeVertex, fragment: compositeFragment,
                pixelFormat: format, blend: .premultiplied)
            #if canImport(MetalFX)
            // Présentation du composite agrandi par MetalFX : échantillon 1:1
            // opaque (réutilise `composite_fragment`).
            presentPipeline = try Renderer.makePipeline(
                device: device, vertex: compositeVertex, fragment: compositeFragment,
                pixelFormat: format, blend: .none)
            #endif
            // Étoiles : points additifs composés sur le ciel, sous le nuage.
            starPipeline = try Renderer.makePipeline(
                device: device, vertex: starVertex, fragment: starFragment,
                pixelFormat: format, blend: .additive)
            // God rays : passe demi-rés HDR (sans blending, comme le ciel)…
            godRaysPipeline = try Renderer.makePipeline(
                device: device, vertex: godRaysVertex, fragment: godRaysFragment,
                pixelFormat: Renderer.cloudColorFormat, blend: .none)
            // …puis composition additive plein écran (réutilise `composite_fragment`).
            godRaysCompositePipeline = try Renderer.makePipeline(
                device: device, vertex: compositeVertex, fragment: compositeFragment,
                pixelFormat: format, blend: .additive)
        } catch {
            return nil
        }

        guard let baker = CoverageBaker(device: device, commandQueue: queue, library: library) else {
            return nil
        }
        coverageBaker = baker

        guard let texture = Renderer.makeLandscapeTexture(device: device) else {
            return nil
        }
        landscapeTexture = texture

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.sampler = sampler

        guard let noise = Renderer.makeNoiseTexture(device: device, library: library, queue: queue) else {
            return nil
        }
        noiseTexture = noise

        self.commandQueue = queue
        super.init()

        log.debug("Renderer initialisé sur \(device.name, privacy: .public)")
        #if canImport(MetalFX)
        let metalFXMode = metalFXSupported ? "actif" : "repli bilinéaire"
        log.info("MetalFX : \(metalFXMode, privacy: .public), échelle \(scale, format: .fixed(precision: 2))")
        #else
        log.info("MetalFX : absent du SDK (simulateur) — repli bilinéaire")
        #endif
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Les cibles demi-rés sont (re)créées paresseusement dans `draw`.
    }

    /// Reçoit la direction du soleil déjà résolue (espace monde) depuis la
    /// Feature. Le Rendering ne dépend pas de l'`AstroService`.
    func updateSunDirection(_ direction: SIMD3<Float>) {
        sunDirection = direction
    }

    /// Reçoit tan(FOV vertical / 2) de la caméra de la scène (zoom de la photo).
    func updateFieldOfView(_ tanHalfFov: Float) {
        cameraTanHalfFov = max(tanHalfFov, 0.02)
    }

    /// Reçoit la base caméra → monde (lacet + tangage du regard) pour le ciel.
    func updateCameraBasis(right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        cameraRight = right
        cameraUp = up
        cameraForward = forward
    }

    /// Reçoit l'éclairage résolu (couleur soleil + ambiance) depuis la Feature.
    func updateLighting(sunColor: SIMD3<Float>, ambient: SIMD3<Float>) {
        self.sunColor = sunColor
        self.skyAmbient = ambient
    }

    /// Reçoit la direction monde du soleil, l'atmosphère et le niveau de sol
    /// pour le ciel dynamique.
    func updateSky(sunDirection: SIMD3<Float>, atmosphere: Atmosphere, groundLight: Float) {
        self.skySunDirection = sunDirection
        self.atmosphere = atmosphere
        self.skyGroundLight = groundLight
    }

    /// Reçoit les couleurs des disques solaire/lunaire (résolues par la Feature ;
    /// la position du soleil/lune réutilise `skySunDirection`/`moonSkyDirection`).
    func updateDiscs(sunColor: SIMD3<Float>, moonColor: SIMD3<Float>) {
        self.sunDiscColor = sunColor
        self.moonDiscColor = moonColor
    }

    /// Reçoit la surface de mer du paysage curé (rendue sous l'horizon).
    func updateSea(_ sea: SeaSurface) {
        self.sea = sea
    }

    /// Reçoit la lune (direction monde + clair de lune + poids nocturne) pour le
    /// reflet/glint sur la mer la nuit.
    func updateMoon(direction: SIMD3<Float>, glint: SIMD3<Float>, nightWeight: Float) {
        self.moonSkyDirection = direction
        self.moonGlint = glint
        self.nightWeight = nightWeight
    }

    /// Reçoit les étoiles visibles (directions monde résolues par la Feature) et
    /// reconstruit le buffer GPU **seulement** si la révision a changé — la
    /// rotation/zoom du regard ne change que la base caméra, pas les directions.
    func updateStars(_ stars: [VisibleStar], revision: Int) {
        guard revision != appliedStarRevision else { return }
        appliedStarRevision = revision
        starCount = stars.count
        guard !stars.isEmpty else {
            starBuffer = nil
            return
        }
        let gpuStars = stars.map { star in
            GPUStar(
                dirMag: SIMD4(star.direction.x, star.direction.y, star.direction.z, star.magnitude),
                extra: SIMD4(star.colorIndex, 0, 0, 0))
        }
        starBuffer = gpuStars.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    /// Reçoit la radiance du ciel (zénith / horizon) pour le reflet de la mer.
    func updateSeaSky(zenith: SIMD3<Float>, horizon: SIMD3<Float>) {
        self.skyZenithRadiance = zenith
        self.skyHorizonRadiance = horizon
    }

    /// Remplace le paysage de fond par l'image fournie (galerie ou photo).
    func setLandscape(_ image: CGImage) {
        let loader = MTKTextureLoader(device: device)
        if let texture = try? loader.newTexture(cgImage: image, options: [.SRGB: false]) {
            landscapeTexture = texture
        }
    }

    /// Reçoit les calques du canvas (modèle multi-coquilles). Le stampage en
    /// couverture directionnelle a lieu dans `draw` (`coverageBaker.reconcile`).
    func updateLayers(_ layers: [CloudLayer]) {
        pendingLayers = layers
    }

    func draw(in view: MTKView) {
        // FPS : nombre d'images sur la dernière seconde, journalisé via os.log.
        fpsFrameCount += 1
        let now = CACurrentMediaTime()
        let span = now - fpsWindowStart
        if span >= 1.0 {
            let fps = Double(self.fpsFrameCount) / span
            log.info("FPS \(fps, format: .fixed(precision: 1))")
            #if DEBUG
            // `draw(in:)` est appelé sur le main thread (CADisplayLink du MTKView).
            MainActor.assumeIsolated { DebugHUD.shared.fps = fps }
            #endif
            fpsFrameCount = 0
            fpsWindowStart = now
        }

        let size = view.drawableSize
        let fullWidth = max(Int(size.width), 1)
        let fullHeight = max(Int(size.height), 1)
        // Échelle interne : ½ (défaut des deux chemins). Chemin MetalFX : le
        // composite reste à cette résolution (lectures 1:1) et le scaler spatial
        // agrandit vers le drawable ; repli : upsample bilinéaire plein écran.
        #if canImport(MetalFX)
        let wantMetalFX = metalFXEnabled && !scalerFailed
        let scale = wantMetalFX ? internalScale : 0.5
        #else
        let scale: Float = 0.5
        #endif
        let halfWidth = max(Int(Float(fullWidth) * scale), 1)
        let halfHeight = max(Int(Float(fullHeight) * scale), 1)
        ensureCloudTargets(width: halfWidth, height: halfHeight)
        #if canImport(MetalFX)
        if wantMetalFX {
            ensureScalerTargets(
                fullWidth: fullWidth, fullHeight: fullHeight,
                halfWidth: halfWidth, halfHeight: halfHeight)
        }
        #endif

        guard let cloudAccum = cloudAccum,
              let skyAccum = skyAccum,
              let skyTarget = skyTarget,
              let godRayTarget = godRayTarget,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let aspect = Float(fullWidth) / Float(fullHeight)
        let elapsed = Float(CACurrentMediaTime() - startTime)

        // Réconcilie l'atlas de couverture directionnelle avec les calques
        // courants (modèle multi-coquilles) : delta incrémental par calque, ou
        // recuisson intégrale sur annulation/effacement.
        coverageBaker.reconcile(layers: pendingLayers)

        // Regard en mouvement (rotation/zoom) depuis la frame précédente : on
        // désactive l'amortissement temporel le temps du mouvement (le nuage est
        // persistant en monde, le rayon sous chaque pixel change → pas d'historique).
        let movedAngle = dot(cameraForward, lastCameraForward) < 0.99999
        let movedZoom = abs(cameraTanHalfFov - lastCameraTanHalfFov) > 1.0e-4
        let cameraMoving = movedAngle || movedZoom
        lastCameraForward = cameraForward
        lastCameraTanHalfFov = cameraTanHalfFov

        // Coquilles marchées (étape 4) : toutes les couches peintes (≤ maxCount),
        // **triées par altitude de coquille croissante** (inner) — la plus basse
        // d'abord, pour la marche front-to-back sans tri côté GPU. La tranche de
        // couverture de chaque coquille reste son index **original** dans
        // `pendingLayers` (ordre de cuisson du baker), distinct de l'index trié.
        let shells = Renderer.makeShells(from: pendingLayers)

        var uniforms = CloudUniforms(
            resolution: SIMD2(Float(halfWidth), Float(halfHeight)),
            time: elapsed,
            aspect: aspect,
            // Direction du soleil résolue par l'AstroService (étape 8).
            sunDirection: SIMD4(sunDirection.x, sunDirection.y, sunDirection.z, 0.0),
            camera: SIMD4(cameraTanHalfFov, nightWeight, 0.0, 0.0),
            lightSun: SIMD4(sunColor.x, sunColor.y, sunColor.z, 0.0),
            lightAmbient: SIMD4(skyAmbient.x, skyAmbient.y, skyAmbient.z, 0.0),
            camRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0.0),
            camUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0.0),
            camForward: SIMD4(cameraForward.x, cameraForward.y, cameraForward.z, 0.0),
            shells: shells.quad,
            layerCount: UInt32(shells.count)
        )
        // Mouvement (ou première frame après réallocation) → refresh complet :
        // stride 1 sur tous les pixels. Au repos → stride 2, cellule active seule.
        let fullRefresh = cameraMoving || cloudAccumDirty
        cloudAccumDirty = false
        var temporal = CloudTemporal(
            activeIndex: fullRefresh ? 0 : Renderer.activeOrder[frameIndex % 4],
            stride: fullRefresh ? 1 : 2)

        // Passe 1 — nuage raymarché par compute dans la cible persistante : au
        // repos seule la cellule active (¼ des pixels) est réécrite, de façon
        // **compacte** (tous les threads marchent → pas de divergence SIMD,
        // contrairement à un fragment plein écran qui sortait tôt sur ¾ des lignes).
        var drawCloud = true
        #if DEBUG
        drawCloud = !Renderer.perfNoCloud
        #endif
        if drawCloud, let cloudEncoder = commandBuffer.makeComputeCommandEncoder() {
            cloudEncoder.setComputePipelineState(cloudPipeline)
            cloudEncoder.setTexture(cloudAccum, index: 0)
            cloudEncoder.setBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 0)
            cloudEncoder.setBytes(&temporal, length: MemoryLayout<CloudTemporal>.stride, index: 1)
            cloudEncoder.setTexture(noiseTexture, index: 1)
            // Atlas de couverture directionnelle (modèle multi-coquilles) :
            // échantillonné en `filter::linear` (R8Unorm filtrable).
            cloudEncoder.setTexture(coverageBaker.atlas, index: 3)
            cloudEncoder.setSamplerState(sampler, index: 0)
            let stride = Int(temporal.stride)
            let gridW = (halfWidth + stride - 1) / stride
            let gridH = (halfHeight + stride - 1) / stride
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            // `dispatchThreadgroups` (portable) + garde de bornes dans le kernel,
            // plutôt que `dispatchThreads` (threadgroups non-uniformes).
            let groups = MTLSize(
                width: (gridW + tg.width - 1) / tg.width,
                height: (gridH + tg.height - 1) / tg.height,
                depth: 1)
            cloudEncoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            cloudEncoder.endEncoding()
        }

        // Passe 2 — ciel atmosphérique + mer raymarchée, hors écran à demi-rés.
        // Interrupteurs perf (DEBUG) : `skyDebugFlag` > 0,5 fait sauter le
        // raymarch atmosphérique côté shader ; `seaEnabledFlag` coupe la mer.
        var skyDebugFlag: Float = 0
        var seaEnabledFlag: Float = sea.enabled ? 1.0 : 0.0
        #if DEBUG
        if Renderer.perfNoSky { skyDebugFlag = 1 }
        if Renderer.perfNoSea { seaEnabledFlag = 0 }
        #endif
        var skyUniforms = SkyUniforms(
            sunDirection: SIMD4(skySunDirection.x, skySunDirection.y, skySunDirection.z, 0.0),
            rayleighScattering: SIMD4(
                atmosphere.rayleighScattering.x, atmosphere.rayleighScattering.y,
                atmosphere.rayleighScattering.z, atmosphere.mieScattering),
            scaleHeights: SIMD4(
                atmosphere.rayleighScaleHeight, atmosphere.mieScaleHeight,
                atmosphere.mieAnisotropy, atmosphere.sunIntensity),
            radii: SIMD4(
                atmosphere.planetRadius, atmosphere.atmosphereRadius,
                atmosphere.eyeHeight, Renderer.skyExposure),
            camera: SIMD4(cameraTanHalfFov, aspect, skyGroundLight, skyDebugFlag),
            camRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0.0),
            camUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0.0),
            camForward: SIMD4(cameraForward.x, cameraForward.y, cameraForward.z, 0.0),
            sea0: SIMD4(seaEnabledFlag, sea.level, sea.height, sea.choppy),
            sea1: SIMD4(sea.frequency, sea.speed, elapsed, 0.0),
            seaBase: SIMD4(sea.baseColor.x, sea.baseColor.y, sea.baseColor.z, 0.0),
            seaWater: SIMD4(sea.waterColor.x, sea.waterColor.y, sea.waterColor.z, 0.0),
            moonDirection: SIMD4(moonSkyDirection.x, moonSkyDirection.y, moonSkyDirection.z, nightWeight),
            moonGlint: SIMD4(moonGlint.x, moonGlint.y, moonGlint.z, 0.0),
            skyZenith: SIMD4(skyZenithRadiance.x, skyZenithRadiance.y, skyZenithRadiance.z, 0.0),
            skyHorizon: SIMD4(skyHorizonRadiance.x, skyHorizonRadiance.y, skyHorizonRadiance.z, 0.0),
            // zw : résolution demi-rés, lue par `sky_radiance_kernel` (positions).
            discParams: SIMD4(
                Renderer.sunAngularRadius, Renderer.moonAngularRadius,
                Float(halfWidth), Float(halfHeight)),
            sunDiscColor: SIMD4(sunDiscColor.x, sunDiscColor.y, sunDiscColor.z, 0.0),
            moonDiscColor: SIMD4(moonDiscColor.x, moonDiscColor.y, moonDiscColor.z, 0.0))

        // Passe 1.5 — radiance atmosphérique du ciel, raymarchée par compute dans
        // `skyAccum`, **amortie** comme le nuage (¼ des pixels au repos). La passe
        // ciel+mer qui suit la lit au lieu de raymarcher (la mer, animée, reste
        // plein régime). Même `temporal` (stride/cellule) que le nuage.
        if let skyKernelEncoder = commandBuffer.makeComputeCommandEncoder() {
            skyKernelEncoder.setComputePipelineState(skyRadiancePipeline)
            skyKernelEncoder.setTexture(skyAccum, index: 0)
            skyKernelEncoder.setBytes(&skyUniforms, length: MemoryLayout<SkyUniforms>.stride, index: 0)
            skyKernelEncoder.setBytes(&temporal, length: MemoryLayout<CloudTemporal>.stride, index: 1)
            let stride = Int(temporal.stride)
            let gridW = (halfWidth + stride - 1) / stride
            let gridH = (halfHeight + stride - 1) / stride
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(
                width: (gridW + tg.width - 1) / tg.width,
                height: (gridH + tg.height - 1) / tg.height,
                depth: 1)
            skyKernelEncoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            skyKernelEncoder.endEncoding()
        }

        let skyPass = MTLRenderPassDescriptor()
        skyPass.colorAttachments[0].texture = skyTarget
        skyPass.colorAttachments[0].loadAction = .dontCare
        skyPass.colorAttachments[0].storeAction = .store
        guard let skyEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: skyPass) else {
            return
        }
        skyEncoder.setRenderPipelineState(skyPipeline)
        skyEncoder.setFragmentBytes(&skyUniforms, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        skyEncoder.setFragmentTexture(landscapeTexture, index: 0)
        skyEncoder.setFragmentTexture(skyAccum, index: 1)
        skyEncoder.setFragmentSamplerState(sampler, index: 0)
        skyEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        skyEncoder.endEncoding()

        // Passe 2.5 — god rays (rayons crépusculaires) hors écran à demi-rés :
        // marche radiale de chaque pixel vers la position écran du soleil, source
        // = lueur solaire × transmittance du nuage (alpha de la passe nuage). Le
        // disque solaire (passe ciel) et le nuage suivent déjà le regard ; on
        // réutilise la même base caméra / FOV / aspect. Auto-éteinte la nuit
        // (couleur du soleil nulle sous l'horizon) et sous couverture totale.
        var godRayUniforms = GodRayUniforms(
            camRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0.0),
            camUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0.0),
            camForward: SIMD4(cameraForward.x, cameraForward.y, cameraForward.z, 0.0),
            camera: SIMD4(cameraTanHalfFov, aspect, 0.0, 0.0),
            sunDirection: SIMD4(skySunDirection.x, skySunDirection.y, skySunDirection.z, 0.0),
            sunColor: SIMD4(sunDiscColor.x, sunDiscColor.y, sunDiscColor.z, 0.0),
            params: SIMD4(
                Renderer.godRayDensity, Renderer.godRayDecay,
                Renderer.godRayWeight, Renderer.godRayIntensity))

        let godRayPass = MTLRenderPassDescriptor()
        godRayPass.colorAttachments[0].texture = godRayTarget
        godRayPass.colorAttachments[0].loadAction = .dontCare
        godRayPass.colorAttachments[0].storeAction = .store
        guard let godRayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: godRayPass) else {
            return
        }
        godRayEncoder.setRenderPipelineState(godRaysPipeline)
        godRayEncoder.setFragmentBytes(
            &godRayUniforms, length: MemoryLayout<GodRayUniforms>.stride, index: 0)
        godRayEncoder.setFragmentTexture(cloudAccum, index: 0)
        godRayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        godRayEncoder.endEncoding()

        // Passes 3+ — composition, upscale MetalFX éventuel, étoiles.
        encodeComposition(
            commandBuffer: commandBuffer, drawableDescriptor: descriptor,
            cloudAccum: cloudAccum, skyTarget: skyTarget, godRayTarget: godRayTarget,
            aspect: aspect, elapsed: elapsed)

        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameIndex &+= 1
    }

    /// Passe 3 — composition : ciel+mer puis nuage « over » prémultiplié, god
    /// rays additifs en dernier (rayons diffusés dans l'air entre le nuage et
    /// l'œil, en surimpression ; la source étant masquée par la couverture, un
    /// nuage épais devant le soleil n'en produit pas), étoiles en dernier.
    /// Chemin MetalFX (cf. `docs/PIPELINE.md` « Upscale MetalFX ») : composé en
    /// demi-rés dans `compositeTarget` (lectures 1:1), agrandi ×2 par le scaler
    /// spatial, présenté par copie opaque ; les étoiles (points 2-7 px que
    /// l'upscale ramollirait) se dessinent en natif dans la présentation,
    /// occultées par la transmittance du nuage dans le shader — strictement
    /// équivalent à l'ancien ordre étoiles-puis-over (termes additifs). Repli :
    /// composé directement dans le drawable plein écran (upsample bilinéaire).
    private func encodeComposition(
        commandBuffer: MTLCommandBuffer,
        drawableDescriptor: MTLRenderPassDescriptor,
        cloudAccum: MTLTexture,
        skyTarget: MTLTexture,
        godRayTarget: MTLTexture,
        aspect: Float,
        elapsed: Float
    ) {
        #if canImport(MetalFX)
        let metalFXActive = metalFXEnabled && !scalerFailed && spatialScaler != nil
        #else
        let metalFXActive = false
        #endif

        var compositeDescriptor = drawableDescriptor
        #if canImport(MetalFX)
        if metalFXActive, let compositeTarget = compositeTarget {
            let offscreen = MTLRenderPassDescriptor()
            offscreen.colorAttachments[0].texture = compositeTarget
            offscreen.colorAttachments[0].loadAction = .dontCare
            offscreen.colorAttachments[0].storeAction = .store
            compositeDescriptor = offscreen
        }
        #endif
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: compositeDescriptor) else {
            return
        }
        compositeEncoder.setRenderPipelineState(compositePipeline)
        compositeEncoder.setFragmentTexture(skyTarget, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.setFragmentTexture(cloudAccum, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.setRenderPipelineState(godRaysCompositePipeline)
        compositeEncoder.setFragmentTexture(godRayTarget, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if !metalFXActive {
            encodeStars(into: compositeEncoder, cloud: cloudAccum, aspect: aspect, elapsed: elapsed)
        }
        compositeEncoder.endEncoding()

        #if canImport(MetalFX)
        // Passes 3.5 + 4 — upscale spatial ×2 puis présentation + étoiles natives.
        if metalFXActive, let scaler = spatialScaler,
           let compositeTarget = compositeTarget, let upscaledTarget = upscaledTarget {
            scaler.colorTexture = compositeTarget
            scaler.outputTexture = upscaledTarget
            scaler.encode(commandBuffer: commandBuffer)

            guard let presentEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: drawableDescriptor) else {
                return
            }
            presentEncoder.setRenderPipelineState(presentPipeline)
            presentEncoder.setFragmentTexture(upscaledTarget, index: 0)
            presentEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encodeStars(into: presentEncoder, cloud: cloudAccum, aspect: aspect, elapsed: elapsed)
            presentEncoder.endEncoding()
        }
        #endif
    }

    /// Étoiles : points additifs world-locked (cf. `Stars.metal`), dessinés en
    /// fin de composition. L'occultation par le nuage se fait dans le shader
    /// (transmittance `1 − α` échantillonnée dans `cloud`), ce qui permet de
    /// les dessiner après le blend « over » — et donc en résolution native sur
    /// le chemin MetalFX. Night-gated par `nightWeight`.
    private func encodeStars(
        into encoder: MTLRenderCommandEncoder,
        cloud: MTLTexture,
        aspect: Float,
        elapsed: Float
    ) {
        guard starCount > 0, let starBuffer = starBuffer else { return }
        var starUniforms = StarUniforms(
            camRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0.0),
            camUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0.0),
            camForward: SIMD4(cameraForward.x, cameraForward.y, cameraForward.z, 0.0),
            params: SIMD4(cameraTanHalfFov, aspect, nightWeight, elapsed))
        encoder.setRenderPipelineState(starPipeline)
        encoder.setVertexBuffer(starBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &starUniforms, length: MemoryLayout<StarUniforms>.stride, index: 1)
        encoder.setFragmentTexture(cloud, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
    }

    // MARK: - Coquilles

    /// Construit les coquilles GPU depuis les calques courants (modèle
    /// multi-coquilles). Plafonne à `CloudLayer.maxCount`, conserve la
    /// **tranche d'atlas** de chaque calque (= son index original dans
    /// `pendingLayers`, ordre de cuisson du baker) puis trie par rayon `inner`
    /// croissant — la plus basse en premier, pour la marche front-to-back. Le tri
    /// dissocie l'ordre de marche de l'index de tranche. Renvoie le tableau trié
    /// et son rembourrage à 4 éléments (tuple attendu par `CloudUniforms`).
    private static func makeShells(from layers: [CloudLayer]) -> (count: Int, quad: ShellQuad) {
        let capped = layers.prefix(CloudLayer.maxCount)
        let shells = capped.enumerated().map { slice, layer -> ShellGPU in
            let spec = layer.genus.shell
            return ShellGPU(
                radii: SIMD4(spec.inner, spec.outer, spec.cloudType, spec.noiseScale),
                drift: SIMD4(spec.drift.x, spec.drift.y, layer.coverageBias, layer.opacity),
                layerSlice: UInt32(slice),
                visible: layer.isVisible ? 1 : 0)
        }
        // Altitude croissante : inner de la coquille. Tri stable non nécessaire
        // (les étages sont disjoints), mais l'ordre fixe garantit le front-to-back.
        .sorted { $0.radii.x < $1.radii.x }

        return (shells.count, ShellQuad(shells))
    }

    // MARK: - Cibles demi-résolution

    /// (Re)crée les cibles hors écran à la demi-résolution courante.
    private func ensureCloudTargets(width: Int, height: Int) {
        if cloudTargetWidth == width, cloudTargetHeight == height, cloudAccum != nil {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.cloudColorFormat, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private

        // Cibles persistantes (nuage + radiance ciel) : écrites par compute,
        // lues par les passes suivantes.
        descriptor.usage = [.shaderRead, .shaderWrite]
        cloudAccum = device.makeTexture(descriptor: descriptor)
        skyAccum = device.makeTexture(descriptor: descriptor)
        cloudAccumDirty = true  // refresh complet à la première frame (pas de bruit)
        cloudTargetWidth = width
        cloudTargetHeight = height

        // Cible du ciel+mer (demi-rés, HDR), recréée avec la cible nuage.
        descriptor.usage = [.renderTarget, .shaderRead]
        skyTarget = device.makeTexture(descriptor: descriptor)
        // Cible des god rays (demi-rés, HDR), même format que le ciel.
        godRayTarget = device.makeTexture(descriptor: descriptor)
        #if canImport(MetalFX)
        // L'entrée du scaler MetalFX suit la même résolution : forcer sa
        // re-création (keyed sur la taille de sortie, qui peut ne pas changer).
        spatialScaler = nil
        #endif
    }

    #if canImport(MetalFX)
    /// (Re)crée le scaler spatial MetalFX et ses cibles : entrée = le composite
    /// demi-rés, sortie = une texture à la taille du drawable, copiée ensuite
    /// par `presentPipeline` (le drawable d'un `MTKView` est `framebufferOnly`,
    /// le scaler ne peut pas l'écrire directement — et les étoiles se dessinent
    /// par-dessus en natif de toute façon).
    private func ensureScalerTargets(
        fullWidth: Int, fullHeight: Int,
        halfWidth: Int, halfHeight: Int
    ) {
        if scalerOutputWidth == fullWidth, scalerOutputHeight == fullHeight, spatialScaler != nil {
            return
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = halfWidth
        descriptor.inputHeight = halfHeight
        descriptor.outputWidth = fullWidth
        descriptor.outputHeight = fullHeight
        descriptor.colorTextureFormat = drawableFormat
        descriptor.outputTextureFormat = drawableFormat
        // Le composite est déjà tonemappé (valeurs display-referred [0,1]).
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            // Création refusée (format/dimensions) : repli bilinéaire définitif,
            // pas de retry par frame.
            scalerFailed = true
            spatialScaler = nil
            log.error("MetalFX : création du scaler refusée — repli bilinéaire")
            return
        }
        scaler.inputContentWidth = halfWidth
        scaler.inputContentHeight = halfHeight

        // Usages exigés par le scaler, en plus de ceux de nos propres passes.
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: drawableFormat, width: halfWidth, height: halfHeight, mipmapped: false)
        inputDescriptor.storageMode = .private
        inputDescriptor.usage = MTLTextureUsage([.renderTarget]).union(scaler.colorTextureUsage)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: drawableFormat, width: fullWidth, height: fullHeight, mipmapped: false)
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = MTLTextureUsage([.shaderRead]).union(scaler.outputTextureUsage)
        guard let input = device.makeTexture(descriptor: inputDescriptor),
              let output = device.makeTexture(descriptor: outputDescriptor) else {
            scalerFailed = true
            spatialScaler = nil
            log.error("MetalFX : allocation des cibles refusée — repli bilinéaire")
            return
        }
        compositeTarget = input
        upscaledTarget = output
        spatialScaler = scaler
        scalerOutputWidth = fullWidth
        scalerOutputHeight = fullHeight
    }
    #endif

    // MARK: - Construction

    private enum Blend {
        case none
        case premultiplied
        case additive
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction,
        pixelFormat: MTLPixelFormat,
        blend: Blend
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment

        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = pixelFormat
        switch blend {
        case .none:
            break
        case .premultiplied:
            // Compositing « over » avec couleur prémultipliée par l'alpha.
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .one
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            // Émission additive (étoiles) : ajoute la couleur, préserve l'alpha
            // du ciel (déjà opaque) pour ne pas perturber la composition « over ».
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .one
            attachment?.sourceAlphaBlendFactor = .zero
            attachment?.destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Bruit Perlin-Worley 3D tileable, précomputé une fois en compute shader
    /// (étape 3). Texture 128³ RGBA : R = Perlin-Worley, GBA = Worley à
    /// fréquences croissantes (cf. `CloudNoise.metal`).
    private static func makeNoiseTexture(
        device: MTLDevice,
        library: MTLLibrary,
        queue: MTLCommandQueue
    ) -> MTLTexture? {
        let size = 128
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor),
              let function = library.makeFunction(name: "generate_cloud_noise"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        let grid = MTLSize(width: size, height: size, depth: size)
        let threads = MTLSize(width: 8, height: 8, depth: 8)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()  // bruit prêt avant le premier rendu
        return texture
    }

    /// Paysage placeholder : dégradé vertical crépusculaire (sol sombre →
    /// horizon chaud → ciel). Remplacé plus tard par la galerie curée / les
    /// photos importées.
    private static func makeLandscapeTexture(device: MTLDevice) -> MTLTexture? {
        let width = 8
        let height = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Origine CG en bas à gauche : du sol (y=0) vers le ciel (y=height).
        let colors = [
            CGColor(red: 0.07, green: 0.06, blue: 0.08, alpha: 1.0), // sol sombre
            CGColor(red: 0.10, green: 0.08, blue: 0.10, alpha: 1.0), // sol
            CGColor(red: 0.96, green: 0.64, blue: 0.40, alpha: 1.0), // horizon chaud
            CGColor(red: 0.46, green: 0.33, blue: 0.40, alpha: 1.0), // ciel médian
            CGColor(red: 0.10, green: 0.13, blue: 0.25, alpha: 1.0)  // ciel haut
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.30, 0.34, 0.55, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            return nil
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: []
        )
        guard let image = context.makeImage() else {
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(cgImage: image, options: [.SRGB: false])
    }
}
