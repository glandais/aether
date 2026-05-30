import CoreGraphics
import MetalKit
import os
import simd

/// Uniforms du shader de nuage. La disposition mémoire doit correspondre à
/// `CloudUniforms` dans `Cloud.metal`. Les cubes (centre + demi-taille) sont
/// passés à part dans un buffer (`CloudCubeGPU`), `cubeCount` en donne le nombre.
private struct CloudUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var aspect: Float
    var sunDirection: SIMD4<Float>
    var weather: SIMD4<Float>
    var camera: SIMD4<Float>  // x: tan(FOV vertical / 2)
    var lightSun: SIMD4<Float>
    var lightAmbient: SIMD4<Float>
    // Base caméra → monde du regard (lacet + tangage), pour le rayon de vue.
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
    var camForward: SIMD4<Float>
    var cubeCount: UInt32   // nombre de cubes valides dans le buffer `cubes`
    var atlasSlabs: UInt32  // nombre total de slabs de l'atlas (= CloudCube.maxCount)
}

/// Un cube de nuage prêt pour le GPU : centre + demi-taille monde. Disposition
/// **identique** à `CloudCubeGPU` dans `Cloud.metal` (deux float4). Sa tranche
/// dans l'atlas de densité est son index (slab `i` ∈ [i·48, (i+1)·48)).
private struct CloudCubeGPU {
    var center: SIMD4<Float>
    var halfSize: SIMD4<Float>
}

/// Un « dab » de pinceau envoyé au compute shader. Doit correspondre à `Dab`
/// dans `BrushPaint.metal`.
private struct Dab {
    var center: SIMD2<Float>
    var radius: Float
    var softness: Float
}

/// Uniforms du stampage : boîte monde + pose caméra du trait, pour projeter
/// chaque voxel vers le canvas peint. Doit correspondre à `StampUniforms` dans
/// `BrushPaint.metal`.
private struct StampUniforms {
    var boxMin: SIMD4<Float>     // xyz: coin min de l'AABB monde
    var boxSize: SIMD4<Float>    // xyz: taille de l'AABB monde
    var boxCenter: SIMD4<Float>  // xyz: centre monde (plan de profondeur du trait)
    var camRight: SIMD4<Float>   // base caméra → monde au moment du trait
    var camUp: SIMD4<Float>
    var camForward: SIMD4<Float>
    var params: SIMD4<Float>     // x: tan(FOV/2) ; y: aspect ; z: sigma profondeur
    var slab: SIMD4<Float>       // x: index du slab cible ; y: profondeur du slab (voxels)
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

/// Rendu de l'étape 4 : le paysage en texture de fond, surmonté d'un nuage dont
/// la forme provient d'un volume de densité 3D peint au pinceau. La sphère
/// analytique des étapes 2-3 est remplacée par ce volume ; le bruit
/// Perlin-Worley (étape 3) en détaille toujours la densité.
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
    private let stampPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    // Paysage : placeholder au départ, remplacé par la Feature (galerie curée)
    // via `setLandscape`.
    private var landscapeTexture: MTLTexture
    private let noiseTexture: MTLTexture
    // Atlas de densité en ping-pong (R8Unorm filtrable) : la repeinte
    // incrémentale lit l'un, écrit l'autre ; le raymarch échantillonne le courant.
    // L'atlas empile `CloudCube.maxCount` tranches (slabs) de `volumeDepth` voxels : un slab
    // par cube de nuage. Le slab `i` occupe la profondeur [i·volumeDepth, …).
    private let densityVolumes: [MTLTexture]
    private var currentVolumeIndex = 0
    // Buffer GPU des cubes (centre + demi-taille) lu par le raymarch (capacité
    // `CloudCube.maxCount`, rempli chaque frame selon les cubes courants).
    private let cubeBuffer: MTLBuffer
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

    // Paramètres météo (étape 9), résolus par la Feature depuis la météo
    // statique du paysage curé. Neutres avant la première mise à jour.
    private var cloudParameters = CloudParameters.neutral

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
    // Profondeur (distance œil → centre du volume), pour l'ancrage en monde.
    private static let volumeDistance: Float = 5.0
    // Demi-extents **monde** figés du volume (boîte à position réelle, ne suit
    // plus le regard ni le FOV courant). « Bande de ciel » : largeur cadrée sur
    // l'aspect au chargement (le nuage occupe la largeur du cadre), hauteur
    // **aplatie** (`volumeHeightFactor`) pour un nuage lointain plutôt qu'une
    // masse proche, profondeur pour l'épaisseur quand on orbite. Calculés une
    // fois (premier draw).
    private static let baseTanHalfFov = Float(tan(Scene.defaultFieldOfView / 2))
    // Largeur un peu plus large que le cadre (présence), hauteur aplatie mais
    // pas écrasée (un nuage bas et large plutôt qu'une masse haute).
    private static let volumeWidthFactor: Float = 1.2
    private static let volumeHeightFactor: Float = 0.7
    private static let volumeHalfDepth: Float = 1.7
    // Soulèvement du centre : la base du volume reste au-dessus de l'horizon
    // (jamais dans la mer), avec ce dégagement de ciel sous le nuage (unités
    // monde, à la profondeur du volume). Faible → nuage bas, proche de l'eau.
    private static let volumeSkyGap: Float = 0.18
    private var volumeHalfExtents: SIMD3<Float>?

    // Résolution d'un slab de densité peint (un cube). La forme y est lisse (le
    // détail vient du bruit Perlin-Worley), donc une résolution modeste suffit.
    private static let volumeWidth = 96
    private static let volumeHeight = 96
    private static let volumeDepth = 48
    // Profondeur de l'atlas : un slab de `volumeDepth` voxels par cube, pour les
    // `CloudCube.maxCount` cubes possibles (source unique de la borne).
    private static let atlasDepth = volumeDepth * CloudCube.maxCount
    // Plafond de dabs **par cube** (borne la boucle d'un dispatch de stampage).
    private static let maxDabs = 768
    private static let cloudColorFormat: MTLPixelFormat = .rgba16Float
    // Épaisseur du dépôt le long du rayon de visée du trait (gaussienne, unités
    // monde) : sans elle, projeter le pinceau peindrait un tube infini à travers
    // la boîte. Centrée sur le plan de profondeur du centre de la boîte.
    private static let stampDepthSigma: Float = 1.0

    // Cubes à stamper, fournis par la Feature ; réconciliés avec l'atlas au début
    // de `draw` (où les centres monde sont connus). Un slab d'atlas par cube.
    private var pendingCubes: [CloudCube] = []
    // État cuit par cube (parallèle aux slabs de l'atlas) : `stampedStrokes` est
    // le reflet exact de ce qui est déjà cuit dans le slab ; `stampedDabCount` le
    // total de dabs cuits (plafonné à `maxDabs`) ; `center` la position monde
    // avec laquelle le slab a été cuit (un changement force une repeinte).
    private struct CubeBake {
        var stampedStrokes: [BrushStroke]
        var stampedDabCount: Int
        var center: SIMD3<Float>
    }
    private var bakes: [CubeBake] = []

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
              let godRaysFragment = library.makeFunction(name: "god_rays_fragment"),
              let stampFunction = library.makeFunction(name: "stamp_density_volume"),
              let clearFunction = library.makeFunction(name: "clear_density_volume") else {
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
            stampPipeline = try device.makeComputePipelineState(function: stampFunction)
            clearPipeline = try device.makeComputePipelineState(function: clearFunction)
        } catch {
            return nil
        }

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

        guard let volumeA = Renderer.makeDensityVolume(device: device),
              let volumeB = Renderer.makeDensityVolume(device: device) else {
            return nil
        }
        densityVolumes = [volumeA, volumeB]

        guard let cubes = device.makeBuffer(
            length: CloudCube.maxCount * MemoryLayout<CloudCubeGPU>.stride,
            options: .storageModeShared) else {
            return nil
        }
        cubeBuffer = cubes

        self.commandQueue = queue
        super.init()

        clearVolume()  // volume vide au départ : ciel sans nuage
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

    /// Reçoit les paramètres de nuage déjà résolus depuis la météo (Feature).
    func updateCloudParameters(_ parameters: CloudParameters) {
        cloudParameters = parameters
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

    /// Reçoit les cubes du canvas (chacun : ancre de regard + traits, coord.
    /// normalisées). Le stampage effectif a lieu dans `draw`, où les centres monde
    /// sont connus (`reconcileVolume`). Plafonné à `CloudCube.maxCount` (slabs de l'atlas).
    func updateCubes(_ cubes: [CloudCube]) {
        pendingCubes = cubes.count > CloudCube.maxCount
            ? Array(cubes.prefix(CloudCube.maxCount)) : cubes
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

        // Demi-extents **monde** figés des cubes (taille uniforme, atlas régulier),
        // calculés une fois (bande de ciel : largeur cadrée, hauteur aplatie).
        let halfExtents = volumeHalfExtents ?? {
            let frameHalf = Renderer.volumeDistance * Renderer.baseTanHalfFov
            let extents = SIMD3<Float>(
                frameHalf * aspect * Renderer.volumeWidthFactor,
                frameHalf * Renderer.volumeHeightFactor,
                Renderer.volumeHalfDepth)
            volumeHalfExtents = extents
            return extents
        }()
        // Centre monde de chaque cube : le long de son ancre de regard, **soulevé**
        // pour que sa base reste au-dessus de l'horizon (jamais dans la mer), quel
        // que soit le regard. L'œil est à l'origine, l'horizon à Y = 0.
        let centers = pendingCubes.map { Renderer.cubeCenter($0.anchorForward, halfExtents: halfExtents) }

        // Réconcilie l'atlas peint avec les cubes courants (centres monde connus) :
        // delta incrémental par cube, ou repeinte intégrale sur
        // annulation/effacement/changement de centre.
        reconcileVolume(cubes: pendingCubes, centers: centers, halfExtents: halfExtents)

        // Remplit le buffer GPU des cubes (centre + demi-taille uniforme) pour le
        // raymarch ; `cubeCount` en borne la lecture côté shader.
        let cubeCount = min(centers.count, CloudCube.maxCount)
        if cubeCount > 0 {
            let gpuCubes = (0..<cubeCount).map { i in
                CloudCubeGPU(
                    center: SIMD4(centers[i].x, centers[i].y, centers[i].z, 0),
                    halfSize: SIMD4(halfExtents.x, halfExtents.y, halfExtents.z, 0))
            }
            gpuCubes.withUnsafeBytes { raw in
                cubeBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }

        // Regard en mouvement (rotation/zoom) depuis la frame précédente : on
        // désactive l'amortissement temporel le temps du mouvement (le nuage est
        // persistant en monde, le rayon sous chaque pixel change → pas d'historique).
        let movedAngle = dot(cameraForward, lastCameraForward) < 0.99999
        let movedZoom = abs(cameraTanHalfFov - lastCameraTanHalfFov) > 1.0e-4
        let cameraMoving = movedAngle || movedZoom
        lastCameraForward = cameraForward
        lastCameraTanHalfFov = cameraTanHalfFov

        var uniforms = CloudUniforms(
            resolution: SIMD2(Float(halfWidth), Float(halfHeight)),
            time: elapsed,
            aspect: aspect,
            // Direction du soleil résolue par l'AstroService (étape 8).
            sunDirection: SIMD4(sunDirection.x, sunDirection.y, sunDirection.z, 0.0),
            weather: SIMD4(cloudParameters.coverageBias, cloudParameters.densityScale, 0.0, 0.0),
            camera: SIMD4(cameraTanHalfFov, 0.0, 0.0, 0.0),
            lightSun: SIMD4(sunColor.x, sunColor.y, sunColor.z, 0.0),
            lightAmbient: SIMD4(skyAmbient.x, skyAmbient.y, skyAmbient.z, 0.0),
            camRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0.0),
            camUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0.0),
            camForward: SIMD4(cameraForward.x, cameraForward.y, cameraForward.z, 0.0),
            cubeCount: UInt32(cubeCount),
            atlasSlabs: UInt32(CloudCube.maxCount)
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
        cloudEncoder.setFragmentBuffer(cubeBuffer, offset: 0, index: 2)
        cloudEncoder.setFragmentTexture(densityVolumes[currentVolumeIndex], index: 0)
        cloudEncoder.setFragmentTexture(noiseTexture, index: 1)
        cloudEncoder.setFragmentTexture(historyTarget, index: 2)
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

    // MARK: - Peinture du volume

    /// Centre monde d'un cube depuis son ancre de regard : le long de l'ancre à
    /// `volumeDistance`, **soulevé** pour que la base du cube reste au-dessus de
    /// l'horizon (jamais dans la mer), quel que soit le regard.
    private static func cubeCenter(_ anchorForward: SIMD3<Float>, halfExtents: SIMD3<Float>) -> SIMD3<Float> {
        var center = anchorForward * volumeDistance
        center.y = max(center.y, halfExtents.y + volumeSkyGap)
        return center
    }

    /// Réconcilie l'atlas peint avec les `cubes` courants (un slab par cube). Si
    /// l'ensemble prolonge l'état cuit (mêmes centres, traits seulement allongés
    /// ou ajoutés), on ne stampe que le delta de chaque cube ; sinon (annulation,
    /// effacement, changement de centre) on repeint tout l'atlas, cube par cube.
    private func reconcileVolume(cubes: [CloudCube], centers: [SIMD3<Float>],
                                 halfExtents: SIMD3<Float>) {
        if !cubesAreExtension(cubes: cubes, centers: centers) {
            // Repeinte intégrale : atlas vide, puis chaque cube dans son slab.
            clearVolume()
            bakes = []
            for c in cubes.indices {
                var dabCount = 0
                for stroke in cubes[c].strokes {
                    if dabCount >= Renderer.maxDabs { break }
                    dabCount += stampStroke(stroke, points: stroke.points[...], slab: c,
                                            center: centers[c], halfExtents: halfExtents,
                                            alreadyStamped: dabCount)
                }
                bakes.append(CubeBake(stampedStrokes: cubes[c].strokes,
                                      stampedDabCount: dabCount, center: centers[c]))
            }
            return
        }

        // Extension pure : delta par cube. Seuls le dernier cube et son dernier
        // trait changent en pratique, mais on balaie chacun (sans delta = sans
        // dispatch). Les cubes neufs ont un slab déjà vide (cf. l'invariant de
        // repeinte : tout slab ≥ `bakes.count` a été remis à zéro).
        for c in cubes.indices {
            if c < bakes.count {
                var dabCount = bakes[c].stampedDabCount
                let baked = bakes[c].stampedStrokes
                // Suite du dernier trait déjà cuit…
                if let lastIdx = baked.indices.last {
                    let bakedPoints = baked[lastIdx].points.count
                    let nowPoints = cubes[c].strokes[lastIdx].points.count
                    if nowPoints > bakedPoints {
                        dabCount += stampStroke(
                            cubes[c].strokes[lastIdx],
                            points: cubes[c].strokes[lastIdx].points[bakedPoints...],
                            slab: c, center: centers[c], halfExtents: halfExtents,
                            alreadyStamped: dabCount)
                    }
                }
                // …puis les traits entièrement nouveaux de ce cube.
                var idx = baked.count
                while idx < cubes[c].strokes.count {
                    if dabCount >= Renderer.maxDabs { break }
                    dabCount += stampStroke(
                        cubes[c].strokes[idx], points: cubes[c].strokes[idx].points[...],
                        slab: c, center: centers[c], halfExtents: halfExtents,
                        alreadyStamped: dabCount)
                    idx += 1
                }
                bakes[c].stampedStrokes = cubes[c].strokes
                bakes[c].stampedDabCount = dabCount
            } else {
                // Cube entièrement neuf (slab vide) : stampe tous ses traits.
                var dabCount = 0
                for stroke in cubes[c].strokes {
                    if dabCount >= Renderer.maxDabs { break }
                    dabCount += stampStroke(stroke, points: stroke.points[...], slab: c,
                                            center: centers[c], halfExtents: halfExtents,
                                            alreadyStamped: dabCount)
                }
                bakes.append(CubeBake(stampedStrokes: cubes[c].strokes,
                                      stampedDabCount: dabCount, center: centers[c]))
            }
        }
    }

    /// L'ensemble des `cubes` prolonge-t-il l'état cuit `bakes` ? Chaque cube déjà
    /// cuit doit garder son centre et ne faire qu'allonger/ajouter ses traits ;
    /// le nombre de cubes ne peut qu'augmenter. Sinon → repeinte intégrale.
    private func cubesAreExtension(cubes: [CloudCube], centers: [SIMD3<Float>]) -> Bool {
        guard cubes.count >= bakes.count else { return false }
        for c in bakes.indices {
            if bakes[c].center != centers[c] { return false }
            if !Renderer.isExtension(of: bakes[c].stampedStrokes, by: cubes[c].strokes) {
                return false
            }
        }
        return true
    }

    /// Les traits `new` prolongent-ils ceux déjà cuits `old` ? (aucun trait
    /// antérieur modifié ; seul le dernier peut s'allonger). Sinon → repeinte.
    private static func isExtension(of old: [BrushStroke], by new: [BrushStroke]) -> Bool {
        guard new.count >= old.count else { return false }
        guard let last = old.indices.last else { return true }  // rien de cuit
        for i in 0..<last where new[i] != old[i] { return false }
        let o = old[last], n = new[last]
        guard o.radius == n.radius, o.softness == n.softness, o.camera == n.camera,
              n.points.count >= o.points.count else { return false }
        return Array(n.points.prefix(o.points.count)) == o.points
    }

    /// Stampe les points d'un trait dans le slab `slab`, via sa pose caméra,
    /// plafonné par `maxDabs` (compteur par cube). Renvoie le nombre de dabs cuits.
    private func stampStroke(_ stroke: BrushStroke, points: ArraySlice<SIMD2<Float>>,
                             slab: Int, center: SIMD3<Float>, halfExtents: SIMD3<Float>,
                             alreadyStamped: Int) -> Int {
        guard !points.isEmpty, alreadyStamped < Renderer.maxDabs else { return 0 }
        let capped = points.prefix(Renderer.maxDabs - alreadyStamped)
        let dabs = capped.map { Dab(center: $0, radius: stroke.radius, softness: stroke.softness) }
        let boxMin = center - halfExtents
        let boxSize = halfExtents * 2
        let cam = stroke.camera
        var uniforms = StampUniforms(
            boxMin: SIMD4(boxMin.x, boxMin.y, boxMin.z, 0),
            boxSize: SIMD4(boxSize.x, boxSize.y, boxSize.z, 0),
            boxCenter: SIMD4(center.x, center.y, center.z, 0),
            camRight: SIMD4(cam.right.x, cam.right.y, cam.right.z, 0),
            camUp: SIMD4(cam.up.x, cam.up.y, cam.up.z, 0),
            camForward: SIMD4(cam.forward.x, cam.forward.y, cam.forward.z, 0),
            params: SIMD4(cam.tanHalfFov, cam.aspect, Renderer.stampDepthSigma, 0),
            slab: SIMD4(Float(slab), Float(Renderer.volumeDepth), 0, 0))
        stampDabs(dabs, uniforms: &uniforms)
        return dabs.count
    }

    /// Stampe les dabs fournis (max-combine avec l'existant) en ping-pong : lit
    /// le volume courant, écrit l'autre, puis bascule. Buffer neuf par appel.
    private func stampDabs(_ dabs: [Dab], uniforms: inout StampUniforms) {
        let count = dabs.count
        guard count > 0 else { return }
        let stride = MemoryLayout<Dab>.stride
        guard let dabBuffer = device.makeBuffer(length: count * stride, options: .storageModeShared) else {
            return
        }
        dabs.withUnsafeBytes { raw in
            dabBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: count * stride)
        }

        let source = densityVolumes[currentVolumeIndex]
        let destination = densityVolumes[1 - currentVolumeIndex]
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        var dabCount = UInt32(count)
        encoder.setComputePipelineState(stampPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(dabBuffer, offset: 0, index: 0)
        encoder.setBytes(&dabCount, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<StampUniforms>.stride, index: 2)
        encoder.dispatchThreads(volumeGrid, threadsPerThreadgroup: volumeThreads)
        encoder.endEncoding()
        commandBuffer.commit()
        currentVolumeIndex = 1 - currentVolumeIndex
    }

    /// Remet les deux volumes de densité à zéro.
    private func clearVolume() {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        encoder.setComputePipelineState(clearPipeline)
        for volume in densityVolumes {
            encoder.setTexture(volume, index: 0)
            encoder.dispatchThreads(volumeGrid, threadsPerThreadgroup: volumeThreads)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        currentVolumeIndex = 0
    }

    private var volumeGrid: MTLSize {
        MTLSize(width: Renderer.volumeWidth, height: Renderer.volumeHeight, depth: Renderer.atlasDepth)
    }
    private var volumeThreads: MTLSize { MTLSize(width: 4, height: 4, depth: 4) }

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

    /// Atlas de densité 3D peint par le pinceau : `CloudCube.maxCount` slabs empilés en
    /// profondeur (un par cube). Mono-canal **R8Unorm** (filtrable sur GPU iOS,
    /// contrairement à R32Float) ; rempli en ping-pong par `stamp_density_volume`
    /// (un slab à la fois, les autres recopiés), vidé par `clear_density_volume`.
    private static func makeDensityVolume(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = volumeWidth
        descriptor.height = volumeHeight
        descriptor.depth = atlasDepth
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
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
