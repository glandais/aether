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
    private let paintPipeline: MTLComputePipelineState
    private let landscapeTexture: MTLTexture
    private let depthTexture: MTLTexture
    private let noiseTexture: MTLTexture
    private let densityVolume: MTLTexture
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

    // Résolution du volume de densité peint. La forme y est lisse (le détail
    // vient du bruit Perlin-Worley), donc une résolution modeste suffit.
    private static let volumeWidth = 96
    private static let volumeHeight = 96
    private static let volumeDepth = 48
    private static let maxDabs = 768
    private static let cloudColorFormat: MTLPixelFormat = .rgba16Float

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
              let paintFunction = library.makeFunction(name: "paint_density_volume") else {
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
            paintPipeline = try device.makeComputePipelineState(function: paintFunction)
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

        guard let volume = Renderer.makeDensityVolume(device: device) else {
            return nil
        }
        densityVolume = volume

        self.commandQueue = queue
        super.init()

        paintDensityVolume([])  // volume vide au départ : ciel sans nuage
        log.debug("Renderer initialisé sur \(device.name, privacy: .public)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Les cibles demi-rés sont (re)créées paresseusement dans `draw`.
    }

    /// Reçoit les traits du canvas (coord. normalisées) et repeint le volume.
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
        paintDensityVolume(dabs)
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
        var uniforms = CloudUniforms(
            resolution: SIMD2(Float(halfWidth), Float(halfHeight)),
            time: Float(CACurrentMediaTime() - startTime),
            aspect: aspect,
            // Soleil bas, chaud, et en partie derrière le nuage (contre-jour)
            // pour la frange argentée du crépuscule.
            sunDirection: SIMD4(0.40, 0.12, -0.50, 0.0),
            // Volume cadré sur le frustum visible à la profondeur z = -5.
            volumeCenter: SIMD4(0.0, 0.0, -5.0, 0.0),
            volumeHalfSize: SIMD4(2.5 * aspect, 2.5, 0.9, 0.0)
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
        cloudEncoder.setFragmentTexture(densityVolume, index: 0)
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

    /// Repeint intégralement le volume de densité à partir des dabs courants.
    /// Un buffer neuf par appel évite toute course avec le GPU.
    private func paintDensityVolume(_ dabs: [Dab]) {
        let count = min(dabs.count, Renderer.maxDabs)
        let stride = MemoryLayout<Dab>.stride
        guard let dabBuffer = device.makeBuffer(length: max(count, 1) * stride, options: .storageModeShared) else {
            return
        }
        if count > 0 {
            dabs.withUnsafeBytes { raw in
                dabBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: count * stride)
            }
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        var dabCount = UInt32(count)
        encoder.setComputePipelineState(paintPipeline)
        encoder.setTexture(densityVolume, index: 0)
        encoder.setBuffer(dabBuffer, offset: 0, index: 0)
        encoder.setBytes(&dabCount, length: MemoryLayout<UInt32>.stride, index: 1)

        let grid = MTLSize(width: Renderer.volumeWidth, height: Renderer.volumeHeight, depth: Renderer.volumeDepth)
        let threads = MTLSize(width: 4, height: 4, depth: 4)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
        encoder.endEncoding()
        commandBuffer.commit()
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

    /// Volume de densité 3D peint par le pinceau (étape 4). Mono-canal,
    /// rempli par `paint_density_volume`.
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
    /// Remplacé plus tard par la vraie profondeur (ARKit / Depth Anything via
    /// `DepthService`).
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
