import CoreGraphics
import MetalKit
import os
import simd

/// Uniforms du shader de nuage. La disposition mémoire doit correspondre à
/// `CloudUniforms` dans `Cloud.metal` (float2, float, float, float4).
private struct CloudUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var aspect: Float
    var sunDirection: SIMD4<Float>
}

/// Rendu de l'étape 2 : le paysage en texture de fond, surmonté d'un nuage
/// analytique unique (sphère de bruit) raymarché et éclairé par un soleil
/// directionnel fixe. Le quad de test de l'étape 1 est remplacé par ce nuage.
final class Renderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let cloudPipeline: MTLRenderPipelineState
    private let landscapeTexture: MTLTexture
    private let noiseTexture: MTLTexture
    private let sampler: MTLSamplerState
    private let startTime = CACurrentMediaTime()
    private let log = Logger(subsystem: "io.github.glandais.aether", category: "Renderer")

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            // Pas de force-unwrap : sans device / bibliothèque Metal, pas de rendu.
            return nil
        }
        view.device = device

        guard let backgroundVertex = library.makeFunction(name: "background_vertex"),
              let backgroundFragment = library.makeFunction(name: "background_fragment"),
              let cloudVertex = library.makeFunction(name: "cloud_vertex"),
              let cloudFragment = library.makeFunction(name: "cloud_fragment") else {
            return nil
        }

        let format = view.colorPixelFormat
        do {
            backgroundPipeline = try Renderer.makePipeline(
                device: device, vertex: backgroundVertex, fragment: backgroundFragment,
                pixelFormat: format, blend: .none)
            cloudPipeline = try Renderer.makePipeline(
                device: device, vertex: cloudVertex, fragment: cloudFragment,
                pixelFormat: format, blend: .premultiplied)
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

        self.commandQueue = queue
        super.init()
        log.debug("Renderer initialisé sur \(device.name, privacy: .public)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // L'aspect est relu à chaque frame depuis la taille du drawable.
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        // 1. Paysage : texture plein écran (triangle couvrant le viewport).
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentTexture(landscapeTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2. Nuage analytique raymarché, composité par-dessus (premultiplied).
        let size = view.drawableSize
        let width = Float(max(size.width, 1))
        let height = Float(max(size.height, 1))
        var uniforms = CloudUniforms(
            resolution: SIMD2(width, height),
            time: Float(CACurrentMediaTime() - startTime),
            aspect: width / height,
            // Soleil bas et chaud, cohérent avec l'horizon du paysage.
            sunDirection: SIMD4(0.55, 0.35, 0.20, 0.0)
        )
        encoder.setRenderPipelineState(cloudPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        encoder.setFragmentTexture(noiseTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Construction

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
