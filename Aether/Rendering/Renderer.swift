import CoreGraphics
import MetalKit
import os
import simd

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
    var cameraMoving: UInt32  // 1 pendant la rotation/zoom du regard
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
    private let cloudPipeline: MTLRenderPipelineState
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

    // Cibles demi-résolution ping-pong pour le raymarch amorti (étape 7).
    private var cloudTargets: [MTLTexture] = []
    private var cloudTargetWidth = 0
    private var cloudTargetHeight = 0
    // Ciel + mer rendus hors écran à demi-résolution (HDR), upsamplés au composite.
    private var skyTarget: MTLTexture?
    // God rays (rayons crépusculaires) rendus hors écran à demi-rés, composés
    // additivement par-dessus tout au passage composite.
    private var godRayTarget: MTLTexture?
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
              let cloudVertex = library.makeFunction(name: "cloud_vertex"),
              let cloudFragment = library.makeFunction(name: "cloud_fragment"),
              let compositeVertex = library.makeFunction(name: "composite_vertex"),
              let compositeFragment = library.makeFunction(name: "composite_fragment"),
              let starVertex = library.makeFunction(name: "star_vertex"),
              let starFragment = library.makeFunction(name: "star_fragment"),
              let godRaysVertex = library.makeFunction(name: "god_rays_vertex"),
              let godRaysFragment = library.makeFunction(name: "god_rays_fragment") else {
            return nil
        }

        let format = view.colorPixelFormat
        do {
            // Ciel atmosphérique dynamique (suit le soleil). `background_vertex`
            // est le triangle plein écran partagé ; échantillonne le paysage
            // sous l'horizon. Rendu **hors écran à demi-résolution** (comme le
            // nuage) : la mer raymarchée y est coûteuse, l'upsample a lieu au
            // passage composite. D'où le format HDR `cloudColorFormat`.
            skyPipeline = try Renderer.makePipeline(
                device: device, vertex: backgroundVertex, fragment: skyFragment,
                pixelFormat: Renderer.cloudColorFormat, blend: .none)
            // Le nuage est rendu hors écran (demi-rés, HDR), sans blending :
            // la composition « over » a lieu au passage composite.
            cloudPipeline = try Renderer.makePipeline(
                device: device, vertex: cloudVertex, fragment: cloudFragment,
                pixelFormat: Renderer.cloudColorFormat, blend: .none)
            compositePipeline = try Renderer.makePipeline(
                device: device, vertex: compositeVertex, fragment: compositeFragment,
                pixelFormat: format, blend: .premultiplied)
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
            log.info("FPS \(Double(self.fpsFrameCount) / span, format: .fixed(precision: 1))")
            fpsFrameCount = 0
            fpsWindowStart = now
        }

        let size = view.drawableSize
        let fullWidth = max(Int(size.width), 1)
        let fullHeight = max(Int(size.height), 1)
        let halfWidth = max(fullWidth / 2, 1)
        let halfHeight = max(fullHeight / 2, 1)
        ensureCloudTargets(width: halfWidth, height: halfHeight)

        guard cloudTargets.count == 2,
              let skyTarget = skyTarget,
              let godRayTarget = godRayTarget,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let writeTarget = cloudTargets[frameIndex % 2]
        let historyTarget = cloudTargets[(frameIndex + 1) % 2]

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
        var temporal = CloudTemporal(
            activeIndex: Renderer.activeOrder[frameIndex % 4],
            cameraMoving: cameraMoving ? 1 : 0)

        // Passe 1 — nuage raymarché hors écran, à demi-résolution, amorti dans
        // le temps (1 cellule 2×2 sur 4 par frame, le reste vient de l'historique).
        let cloudPass = MTLRenderPassDescriptor()
        cloudPass.colorAttachments[0].texture = writeTarget
        cloudPass.colorAttachments[0].loadAction = .dontCare
        cloudPass.colorAttachments[0].storeAction = .store
        guard let cloudEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cloudPass) else {
            return
        }
        cloudEncoder.setRenderPipelineState(cloudPipeline)
        cloudEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        cloudEncoder.setFragmentBytes(&temporal, length: MemoryLayout<CloudTemporal>.stride, index: 1)
        cloudEncoder.setFragmentTexture(noiseTexture, index: 1)
        cloudEncoder.setFragmentTexture(historyTarget, index: 2)
        // Atlas de couverture directionnelle (modèle multi-coquilles) :
        // échantillonné en `filter::linear` (R8Unorm filtrable).
        cloudEncoder.setFragmentTexture(coverageBaker.atlas, index: 3)
        cloudEncoder.setFragmentSamplerState(sampler, index: 0)
        cloudEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        cloudEncoder.endEncoding()

        // Passe 2 — ciel atmosphérique + mer raymarchée, hors écran à demi-rés.
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
            camera: SIMD4(cameraTanHalfFov, aspect, skyGroundLight, 0.0),
            camRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0.0),
            camUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0.0),
            camForward: SIMD4(cameraForward.x, cameraForward.y, cameraForward.z, 0.0),
            sea0: SIMD4(sea.enabled ? 1.0 : 0.0, sea.level, sea.height, sea.choppy),
            sea1: SIMD4(sea.frequency, sea.speed, elapsed, 0.0),
            seaBase: SIMD4(sea.baseColor.x, sea.baseColor.y, sea.baseColor.z, 0.0),
            seaWater: SIMD4(sea.waterColor.x, sea.waterColor.y, sea.waterColor.z, 0.0),
            moonDirection: SIMD4(moonSkyDirection.x, moonSkyDirection.y, moonSkyDirection.z, nightWeight),
            moonGlint: SIMD4(moonGlint.x, moonGlint.y, moonGlint.z, 0.0),
            skyZenith: SIMD4(skyZenithRadiance.x, skyZenithRadiance.y, skyZenithRadiance.z, 0.0),
            skyHorizon: SIMD4(skyHorizonRadiance.x, skyHorizonRadiance.y, skyHorizonRadiance.z, 0.0),
            discParams: SIMD4(Renderer.sunAngularRadius, Renderer.moonAngularRadius, 0.0, 0.0),
            sunDiscColor: SIMD4(sunDiscColor.x, sunDiscColor.y, sunDiscColor.z, 0.0),
            moonDiscColor: SIMD4(moonDiscColor.x, moonDiscColor.y, moonDiscColor.z, 0.0))

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
        godRayEncoder.setFragmentTexture(writeTarget, index: 0)
        godRayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        godRayEncoder.endEncoding()

        // Passe 3 — composition plein écran : ciel+mer puis nuage, tous deux
        // demi-rés upsamplés (bilinéaire) et composés « over » prémultiplié.
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        compositeEncoder.setRenderPipelineState(compositePipeline)
        compositeEncoder.setFragmentTexture(skyTarget, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Étoiles : points additifs sur le ciel, **avant** le nuage (qui les
        // occulte). Mêmes base caméra / FOV / aspect que le ciel → coïncidence
        // au pixel près. Night-gated par `nightWeight`.
        if starCount > 0, let starBuffer = starBuffer {
            var starUniforms = StarUniforms(
                camRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0.0),
                camUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0.0),
                camForward: SIMD4(cameraForward.x, cameraForward.y, cameraForward.z, 0.0),
                params: SIMD4(cameraTanHalfFov, aspect, nightWeight, elapsed))
            compositeEncoder.setRenderPipelineState(starPipeline)
            compositeEncoder.setVertexBuffer(starBuffer, offset: 0, index: 0)
            compositeEncoder.setVertexBytes(
                &starUniforms, length: MemoryLayout<StarUniforms>.stride, index: 1)
            compositeEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
        }

        // Nuage upsamplé « over » le ciel + les étoiles : restaurer le pipeline
        // composite et la texture nuage après le draw des points.
        compositeEncoder.setRenderPipelineState(compositePipeline)
        compositeEncoder.setFragmentTexture(writeTarget, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // God rays composés **en dernier**, additivement par-dessus tout : ce
        // sont des rayons diffusés dans l'air entre le nuage et l'œil, donc en
        // surimpression. La source étant masquée par la couverture, un nuage
        // épais juste devant le soleil ne produit aucun rayon à cet endroit.
        compositeEncoder.setRenderPipelineState(godRaysCompositePipeline)
        compositeEncoder.setFragmentTexture(godRayTarget, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameIndex &+= 1
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

    /// (Re)crée les deux cibles ping-pong à la demi-résolution courante.
    private func ensureCloudTargets(width: Int, height: Int) {
        if cloudTargetWidth == width, cloudTargetHeight == height, cloudTargets.count == 2 {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.cloudColorFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        var targets: [MTLTexture] = []
        for _ in 0..<2 {
            guard let target = device.makeTexture(descriptor: descriptor) else { return }
            targets.append(target)
        }
        cloudTargets = targets
        cloudTargetWidth = width
        cloudTargetHeight = height
        // Vider l'historique : sinon les pixels non actifs lisent du bruit
        // pendant les premières frames (jusqu'au remplissage du cycle 2×2).
        for target in targets {
            clear(target)
        }

        // Cible du ciel+mer (demi-rés, HDR), recréée avec les cibles nuage.
        descriptor.usage = [.renderTarget, .shaderRead]
        skyTarget = device.makeTexture(descriptor: descriptor)
        // Cible des god rays (demi-rés, HDR), même format que le ciel.
        godRayTarget = device.makeTexture(descriptor: descriptor)
    }

    private func clear(_ texture: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        if let commandBuffer = commandQueue.makeCommandBuffer(),
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
            commandBuffer.commit()
        }
    }

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
