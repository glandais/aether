import CoreGraphics
import MetalKit
import os
import simd

/// Uniforms du shader de nuage. La disposition mémoire doit correspondre à
/// `CloudUniforms` dans `Cloud.metal`.
private struct CloudUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var aspect: Float
    var sunDirection: SIMD4<Float>
    var volumeCenter: SIMD4<Float>
    var volumeHalfSize: SIMD4<Float>
    var weather: SIMD4<Float>
    var camera: SIMD4<Float>  // x: tan(FOV vertical / 2)
    var lightSun: SIMD4<Float>
    var lightAmbient: SIMD4<Float>
}

/// Un « dab » de pinceau envoyé au compute shader. Doit correspondre à `Dab`
/// dans `BrushPaint.metal`.
private struct Dab {
    var center: SIMD2<Float>
    var radius: Float
    var softness: Float
}

/// Amortissement temporel (étape 7). Doit correspondre à `CloudTemporal` dans
/// `Cloud.metal`.
private struct CloudTemporal {
    var activeIndex: UInt32
}

/// Rendu de l'étape 4 : le paysage en texture de fond, surmonté d'un nuage dont
/// la forme provient d'un volume de densité 3D peint au pinceau. La sphère
/// analytique des étapes 2-3 est remplacée par ce volume ; le bruit
/// Perlin-Worley (étape 3) en détaille toujours la densité.
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let cloudPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let stampPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    // Paysage + depth map : placeholders au départ, remplacés par la Feature
    // (galerie curée ou photo importée) via `setLandscape` / `setDepthMap`.
    private var landscapeTexture: MTLTexture
    private var depthTexture: MTLTexture
    private let noiseTexture: MTLTexture
    // Volume de densité en ping-pong (R8Unorm filtrable) : la repeinte
    // incrémentale lit l'un, écrit l'autre ; le raymarch échantillonne le courant.
    private let densityVolumes: [MTLTexture]
    private var currentVolumeIndex = 0
    private let sampler: MTLSamplerState
    private let startTime = CACurrentMediaTime()
    private let log = Logger(subsystem: "io.github.glandais.aether", category: "Renderer")

    // Cibles demi-résolution ping-pong pour le raymarch amorti (étape 7).
    private var cloudTargets: [MTLTexture] = []
    private var cloudTargetWidth = 0
    private var cloudTargetHeight = 0
    private var frameIndex = 0
    // Ordre de Bayer 2×2 : répartit les 4 cellules sur 4 frames.
    private static let activeOrder: [UInt32] = [0, 3, 1, 2]

    // Direction du soleil (vers l'astre), résolue par la Feature depuis
    // l'`AstroService` (étape 8). Valeur de repli avant la première mise à jour.
    private var sunDirection = SIMD3<Float>(0.40, 0.12, -0.50)

    // Paramètres météo (étape 9), résolus par la Feature depuis la météo
    // statique du paysage curé. Neutres avant la première mise à jour.
    private var cloudParameters = CloudParameters.neutral

    // tan(FOV vertical / 2) de la caméra de la scène (défaut ≈ 53°). Cale la
    // projection du ciel et le cadrage du volume sur le zoom de la photo.
    private var cameraTanHalfFov: Float = 0.5

    // Éclairage résolu par la Feature (couleur soleil par altitude × exposition
    // de la photo, et ambiance ciel). Valeurs de repli avant mise à jour.
    private var sunColor = SIMD3<Float>(6.5, 4.7, 3.4)
    private var skyAmbient = SIMD3<Float>(0.34, 0.40, 0.55)
    // Profondeur (distance caméra → centre du volume), pour le cadrage.
    private static let volumeDistance: Float = 5.0

    // Résolution du volume de densité peint. La forme y est lisse (le détail
    // vient du bruit Perlin-Worley), donc une résolution modeste suffit.
    private static let volumeWidth = 96
    private static let volumeHeight = 96
    private static let volumeDepth = 48
    private static let maxDabs = 768
    private static let cloudColorFormat: MTLPixelFormat = .rgba16Float

    // Nombre de dabs déjà stampés dans le volume (repeinte incrémentale).
    private var stampedDabCount = 0

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
              let backgroundFragment = library.makeFunction(name: "background_fragment"),
              let cloudVertex = library.makeFunction(name: "cloud_vertex"),
              let cloudFragment = library.makeFunction(name: "cloud_fragment"),
              let compositeVertex = library.makeFunction(name: "composite_vertex"),
              let compositeFragment = library.makeFunction(name: "composite_fragment"),
              let stampFunction = library.makeFunction(name: "stamp_density_volume"),
              let clearFunction = library.makeFunction(name: "clear_density_volume") else {
            return nil
        }

        let format = view.colorPixelFormat
        do {
            backgroundPipeline = try Renderer.makePipeline(
                device: device, vertex: backgroundVertex, fragment: backgroundFragment,
                pixelFormat: format, blend: .none)
            // Le nuage est rendu hors écran (demi-rés, HDR), sans blending :
            // la composition « over » a lieu au passage composite.
            cloudPipeline = try Renderer.makePipeline(
                device: device, vertex: cloudVertex, fragment: cloudFragment,
                pixelFormat: Renderer.cloudColorFormat, blend: .none)
            compositePipeline = try Renderer.makePipeline(
                device: device, vertex: compositeVertex, fragment: compositeFragment,
                pixelFormat: format, blend: .premultiplied)
            stampPipeline = try device.makeComputePipelineState(function: stampFunction)
            clearPipeline = try device.makeComputePipelineState(function: clearFunction)
        } catch {
            return nil
        }

        guard let texture = Renderer.makeLandscapeTexture(device: device) else {
            return nil
        }
        landscapeTexture = texture

        guard let depth = Renderer.makeDepthTexture(device: device) else {
            return nil
        }
        depthTexture = depth

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

    /// Reçoit l'éclairage résolu (couleur soleil + ambiance) depuis la Feature.
    func updateLighting(sunColor: SIMD3<Float>, ambient: SIMD3<Float>) {
        self.sunColor = sunColor
        self.skyAmbient = ambient
    }

    /// Remplace le paysage de fond par l'image fournie (galerie ou photo).
    func setLandscape(_ image: CGImage) {
        let loader = MTKTextureLoader(device: device)
        if let texture = try? loader.newTexture(cgImage: image, options: [.SRGB: false]) {
            landscapeTexture = texture
        }
    }

    /// Remplace la depth map par celle résolue (LiDAR / Depth Anything). La
    /// profondeur relative [0,1] (0 = proche, 1 = lointain) est mappée en
    /// distance scène : masque d'occlusion tolérant (BIBLIO §4), le nuage
    /// n'apparaît que dans le ciel (zones les plus lointaines).
    func setDepthMap(_ depthMap: DepthMap) {
        guard depthMap.width > 0, depthMap.height > 0,
              depthMap.values.count == depthMap.width * depthMap.height else {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: depthMap.width, height: depthMap.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        // d ≤ skyLow → relief proche (occlut) ; d ≥ skyHigh → ciel (lointain).
        let skyLow: Float = 0.55
        let skyHigh: Float = 0.78
        let nearDistance: Float = 2.0
        let far: Float = 1000.0
        let sceneDepths = depthMap.values.map { d -> Float in
            let t = Renderer.smoothstep(skyLow, skyHigh, d)
            return nearDistance + (far - nearDistance) * t
        }
        sceneDepths.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, depthMap.width, depthMap.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: depthMap.width * MemoryLayout<Float>.stride
            )
        }
        depthTexture = texture
    }

    /// Reçoit les traits du canvas (coord. normalisées) et met à jour le volume
    /// de façon incrémentale : seuls les dabs ajoutés depuis la dernière mise à
    /// jour sont stampés. Un trait qui s'allonge coûte O(nouveaux dabs).
    func updateStrokes(_ strokes: [BrushStroke]) {
        var dabs: [Dab] = []
        outer: for stroke in strokes {
            for point in stroke.points {
                dabs.append(Dab(center: point, radius: stroke.radius, softness: stroke.softness))
                if dabs.count >= Renderer.maxDabs {
                    break outer
                }
            }
        }

        if dabs.count == stampedDabCount {
            return  // rien de nouveau
        }
        if dabs.count < stampedDabCount {
            // Effacement / réinitialisation : on repart d'un volume vide.
            clearVolume()
            stampedDabCount = 0
        }
        if dabs.count > stampedDabCount {
            stampDabs(Array(dabs[stampedDabCount..<dabs.count]))
            stampedDabCount = dabs.count
        }
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        let fullWidth = max(Int(size.width), 1)
        let fullHeight = max(Int(size.height), 1)
        let halfWidth = max(fullWidth / 2, 1)
        let halfHeight = max(fullHeight / 2, 1)
        ensureCloudTargets(width: halfWidth, height: halfHeight)

        guard cloudTargets.count == 2,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let writeTarget = cloudTargets[frameIndex % 2]
        let historyTarget = cloudTargets[(frameIndex + 1) % 2]

        let aspect = Float(fullWidth) / Float(fullHeight)
        let volumeHalfHeight = Renderer.volumeDistance * cameraTanHalfFov
        var uniforms = CloudUniforms(
            resolution: SIMD2(Float(halfWidth), Float(halfHeight)),
            time: Float(CACurrentMediaTime() - startTime),
            aspect: aspect,
            // Direction du soleil résolue par l'AstroService (étape 8).
            sunDirection: SIMD4(sunDirection.x, sunDirection.y, sunDirection.z, 0.0),
            // Volume cadré sur le frustum visible à la profondeur du volume,
            // selon le FOV de la caméra (zoom) et l'aspect de l'écran.
            volumeCenter: SIMD4(0.0, 0.0, -Renderer.volumeDistance, 0.0),
            volumeHalfSize: SIMD4(volumeHalfHeight * aspect, volumeHalfHeight, 0.9, 0.0),
            weather: SIMD4(cloudParameters.coverageBias, cloudParameters.densityScale, 0.0, 0.0),
            camera: SIMD4(cameraTanHalfFov, 0.0, 0.0, 0.0),
            lightSun: SIMD4(sunColor.x, sunColor.y, sunColor.z, 0.0),
            lightAmbient: SIMD4(skyAmbient.x, skyAmbient.y, skyAmbient.z, 0.0)
        )
        var temporal = CloudTemporal(activeIndex: Renderer.activeOrder[frameIndex % 4])

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
        cloudEncoder.setFragmentTexture(densityVolumes[currentVolumeIndex], index: 0)
        cloudEncoder.setFragmentTexture(noiseTexture, index: 1)
        cloudEncoder.setFragmentTexture(depthTexture, index: 2)
        cloudEncoder.setFragmentTexture(historyTarget, index: 3)
        cloudEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        cloudEncoder.endEncoding()

        // Passe 2 — composition plein écran : paysage + nuage demi-rés upsamplé.
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        compositeEncoder.setRenderPipelineState(backgroundPipeline)
        compositeEncoder.setFragmentTexture(landscapeTexture, index: 0)
        compositeEncoder.setFragmentSamplerState(sampler, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        compositeEncoder.setRenderPipelineState(compositePipeline)
        compositeEncoder.setFragmentTexture(writeTarget, index: 0)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameIndex &+= 1
    }

    // MARK: - Peinture du volume

    /// Stampe les dabs fournis (max-combine avec l'existant) en ping-pong : lit
    /// le volume courant, écrit l'autre, puis bascule. Buffer neuf par appel.
    private func stampDabs(_ dabs: [Dab]) {
        let count = min(dabs.count, Renderer.maxDabs)
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
        MTLSize(width: Renderer.volumeWidth, height: Renderer.volumeHeight, depth: Renderer.volumeDepth)
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

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private enum Blend {
        case none
        case premultiplied
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
        if case .premultiplied = blend {
            // Compositing « over » avec couleur prémultipliée par l'alpha.
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .one
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
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

    /// Volume de densité 3D peint par le pinceau. Mono-canal **R8Unorm**
    /// (filtrable sur GPU iOS, contrairement à R32Float) ; rempli en ping-pong
    /// par `stamp_density_volume`, vidé par `clear_density_volume`.
    private static func makeDensityVolume(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = volumeWidth
        descriptor.height = volumeHeight
        descriptor.depth = volumeDepth
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Depth map placeholder du paysage (étape 6) : distance scène le long du
    /// rayon, par ligne d'écran. Ciel = lointain (le nuage passe devant) ; bande
    /// de sol en bas = proche et se rapprochant vers le bas (occlut le nuage).
    /// La depth map synthétique des paysages curés (`LandscapeFactory`) la
    /// remplace via `setDepthMap`.
    private static func makeDepthTexture(device: MTLDevice) -> MTLTexture? {
        let width = 1
        let height = 512
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Le ciel est lointain (le nuage, vers z = -5 ≈ t 5.5, passe devant) ;
        // la bande de sol est un relief proche qui occlut le nuage. Le sol
        // descend en douceur à travers la profondeur du nuage → coupe souple.
        let far: Float = 1000.0
        let ridgeStart: Float = 0.50  // début du relief en coord. écran (0 = haut)
        let ridgeNear: Float = 1.4    // profondeur au bas de l'écran (très proche)
        let ridgeFar: Float = 6.0     // profondeur au sommet du relief
        var depths = [Float](repeating: far, count: width * height)
        for row in 0..<height {
            let v = Float(row) / Float(height - 1)  // 0 = haut (ciel), 1 = bas (sol)
            if v < ridgeStart {
                depths[row] = far
            } else {
                let t = Renderer.smoothstep(ridgeStart, 0.95, v)
                depths[row] = ridgeFar + (ridgeNear - ridgeFar) * t
            }
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: depths,
            bytesPerRow: width * MemoryLayout<Float>.stride
        )
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
