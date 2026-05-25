import CoreGraphics
import MetalKit
import os

/// Rendu de l'étape 1 : le paysage en texture de fond plein écran, surmonté
/// d'un quad de test composité (alpha blending). Les étapes suivantes
/// (raymarching, volume textures, scattering) remplaceront le quad par les
/// nuages volumétriques.
final class Renderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let testQuadPipeline: MTLRenderPipelineState
    private let landscapeTexture: MTLTexture
    private let sampler: MTLSamplerState
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
              let testQuadVertex = library.makeFunction(name: "testquad_vertex"),
              let testQuadFragment = library.makeFunction(name: "testquad_fragment") else {
            return nil
        }

        let format = view.colorPixelFormat
        do {
            backgroundPipeline = try Renderer.makePipeline(
                device: device, vertex: backgroundVertex, fragment: backgroundFragment,
                pixelFormat: format, blending: false)
            testQuadPipeline = try Renderer.makePipeline(
                device: device, vertex: testQuadVertex, fragment: testQuadFragment,
                pixelFormat: format, blending: true)
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

        self.commandQueue = queue
        super.init()
        log.debug("Renderer initialisé sur \(device.name, privacy: .public)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Aucun état dépendant de la taille à recalculer pour l'instant.
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

        // 2. Quad de test composité par-dessus (alpha blending).
        encoder.setRenderPipelineState(testQuadPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Construction

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction,
        pixelFormat: MTLPixelFormat,
        blending: Bool
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment

        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = pixelFormat
        if blending {
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .sourceAlpha
            attachment?.sourceAlphaBlendFactor = .sourceAlpha
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
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
