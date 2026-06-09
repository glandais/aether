import MetalKit
import simd

/// Cuit la **couverture directionnelle** des calques (modèle multi-coquilles,
/// cf. `docs/SHELLS.md` §5) dans un atlas équirectangulaire de l'hémisphère
/// supérieur. Possède l'atlas (ping-pong R8Unorm, une tranche par calque), les
/// pipelines de stamp/clear et l'état cuit. Le `Renderer` lui délègue le
/// stampage ; le raymarch concentrique (à partir de l'étape 3) lira `atlas`.
///
/// Ce baker est l'analogue 2D directionnel du chemin cube (atlas de densité 3D)
/// du `Renderer`. Il reprend la même réconciliation incrémentale : delta par
/// calque tant que les traits ne font que s'allonger/s'ajouter, repeinte
/// intégrale sinon (annulation, effacement, réordonnancement).
final class CoverageBaker {
    /// Uniforms du stamp de couverture. Doit correspondre à
    /// `CoverageStampUniforms` dans `BrushPaint.metal`.
    private struct CoverageStampUniforms {
        var camRight: SIMD4<Float>
        var camUp: SIMD4<Float>
        var camForward: SIMD4<Float>
        var params: SIMD4<Float>  // x: tan(FOV/2) ; y: aspect ; z: tranche cible
    }

    /// Un « dab » de pinceau. Doit correspondre à `Dab` dans `BrushPaint.metal`.
    private struct Dab {
        var center: SIMD2<Float>
        var radius: Float
        var softness: Float
    }

    /// État cuit d'un calque : reflet exact des traits déposés et total de dabs
    /// cuits (plafonné à `maxDabs`).
    private struct LayerBake {
        var stampedStrokes: [BrushStroke]
        var stampedDabCount: Int
    }

    // Atlas équirectangulaire de l'hémisphère supérieur (azimut × élévation).
    private static let width = 1024
    private static let height = 512
    // Plafond de dabs **par calque** (borne la boucle d'un dispatch de stamp).
    private static let maxDabs = 768

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let stampPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let atlases: [MTLTexture]
    private var currentIndex = 0
    private var bakes: [LayerBake] = []

    // Atlas courant lisible par le raymarch concentrique (`Cloud.metal`),
    // échantillonné en `filter::linear` (R8Unorm filtrable sur GPU iOS).
    var atlas: MTLTexture { atlases[currentIndex] }

    init?(device: MTLDevice, commandQueue: MTLCommandQueue, library: MTLLibrary) {
        guard let stampFunction = library.makeFunction(name: "stamp_coverage_map"),
              let clearFunction = library.makeFunction(name: "clear_coverage_map"),
              let stamp = try? device.makeComputePipelineState(function: stampFunction),
              let clear = try? device.makeComputePipelineState(function: clearFunction),
              let atlasA = Self.makeAtlas(device: device),
              let atlasB = Self.makeAtlas(device: device) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.stampPipeline = stamp
        self.clearPipeline = clear
        self.atlases = [atlasA, atlasB]
        clearAtlases()  // atlas vide au départ : ciel sans couverture
    }

    /// Réconcilie l'atlas avec les `layers` courants (une tranche par calque).
    /// Plafonné à `CloudLayer.maxCount` tranches.
    func reconcile(layers: [CloudLayer]) {
        let layers = layers.count > CloudLayer.maxCount
            ? Array(layers.prefix(CloudLayer.maxCount)) : layers
        if !layersAreExtension(layers) {
            clearAtlases()
            bakes = []
            for slice in layers.indices {
                bakes.append(bakeAll(layers[slice].strokes, slice: slice))
            }
            return
        }

        // Extension pure : delta par calque (allongement du dernier trait cuit,
        // puis traits entièrement nouveaux).
        for slice in layers.indices {
            guard slice < bakes.count else {
                bakes.append(bakeAll(layers[slice].strokes, slice: slice))
                continue
            }
            var dabCount = bakes[slice].stampedDabCount
            let baked = bakes[slice].stampedStrokes
            if let lastIdx = baked.indices.last {
                let bakedPoints = baked[lastIdx].points.count
                let nowPoints = layers[slice].strokes[lastIdx].points.count
                if nowPoints > bakedPoints {
                    dabCount += stampStroke(
                        layers[slice].strokes[lastIdx],
                        points: layers[slice].strokes[lastIdx].points[bakedPoints...],
                        slice: slice, alreadyStamped: dabCount)
                }
            }
            var idx = baked.count
            while idx < layers[slice].strokes.count {
                if dabCount >= Self.maxDabs { break }
                dabCount += stampStroke(
                    layers[slice].strokes[idx], points: layers[slice].strokes[idx].points[...],
                    slice: slice, alreadyStamped: dabCount)
                idx += 1
            }
            bakes[slice].stampedStrokes = layers[slice].strokes
            bakes[slice].stampedDabCount = dabCount
        }
    }

    /// Cuit tous les traits d'une tranche vide (calque neuf ou repeinte).
    private func bakeAll(_ strokes: [BrushStroke], slice: Int) -> LayerBake {
        var dabCount = 0
        for stroke in strokes {
            if dabCount >= Self.maxDabs { break }
            dabCount += stampStroke(stroke, points: stroke.points[...], slice: slice,
                                    alreadyStamped: dabCount)
        }
        return LayerBake(stampedStrokes: strokes, stampedDabCount: dabCount)
    }

    /// Les `layers` prolongent-ils l'état cuit ? Chaque calque déjà cuit ne peut
    /// qu'allonger/ajouter ses traits ; le nombre de calques ne peut qu'augmenter.
    private func layersAreExtension(_ layers: [CloudLayer]) -> Bool {
        guard layers.count >= bakes.count else { return false }
        for slice in bakes.indices
        where !Self.isExtension(of: bakes[slice].stampedStrokes, by: layers[slice].strokes) {
            return false
        }
        return true
    }

    /// Les traits `new` prolongent-ils ceux déjà cuits `old` ? (aucun trait
    /// antérieur modifié ; seul le dernier peut s'allonger).
    private static func isExtension(of old: [BrushStroke], by new: [BrushStroke]) -> Bool {
        guard new.count >= old.count else { return false }
        guard let last = old.indices.last else { return true }  // rien de cuit
        for i in 0..<last where new[i] != old[i] { return false }
        let o = old[last], n = new[last]
        guard o.radius == n.radius, o.softness == n.softness, o.camera == n.camera,
              n.points.count >= o.points.count else { return false }
        return Array(n.points.prefix(o.points.count)) == o.points
    }

    /// Stampe les points d'un trait dans la tranche `slice`, via sa pose caméra,
    /// plafonné par `maxDabs`. Renvoie le nombre de dabs cuits.
    private func stampStroke(_ stroke: BrushStroke, points: ArraySlice<SIMD2<Float>>,
                             slice: Int, alreadyStamped: Int) -> Int {
        guard !points.isEmpty, alreadyStamped < Self.maxDabs else { return 0 }
        let capped = points.prefix(Self.maxDabs - alreadyStamped)
        let dabs = capped.map { Dab(center: $0, radius: stroke.radius, softness: stroke.softness) }
        let cam = stroke.camera
        var uniforms = CoverageStampUniforms(
            camRight: SIMD4(cam.right.x, cam.right.y, cam.right.z, 0),
            camUp: SIMD4(cam.up.x, cam.up.y, cam.up.z, 0),
            camForward: SIMD4(cam.forward.x, cam.forward.y, cam.forward.z, 0),
            params: SIMD4(cam.tanHalfFov, cam.aspect, Float(slice), 0))
        stampDabs(dabs, uniforms: &uniforms)
        return dabs.count
    }

    /// Stampe les dabs (max-combine avec l'existant) en ping-pong : lit l'atlas
    /// courant, écrit l'autre, puis bascule. Le kernel n'écrit que la tranche
    /// cible : un blit recopie d'abord toutes les tranches source → destination,
    /// sans quoi la bascule perdrait la couverture des autres calques.
    /// Buffer neuf par appel.
    private func stampDabs(_ dabs: [Dab], uniforms: inout CoverageStampUniforms) {
        let count = dabs.count
        guard count > 0 else { return }
        let stride = MemoryLayout<Dab>.stride
        guard let dabBuffer = device.makeBuffer(length: count * stride, options: .storageModeShared) else {
            return
        }
        dabs.withUnsafeBytes { raw in
            dabBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: count * stride)
        }

        let source = atlases[currentIndex]
        let destination = atlases[1 - currentIndex]
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  to: destination, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: CloudLayer.maxCount, levelCount: 1)
        blit.endEncoding()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        var dabCount = UInt32(count)
        encoder.setComputePipelineState(stampPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(dabBuffer, offset: 0, index: 0)
        encoder.setBytes(&dabCount, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<CoverageStampUniforms>.stride, index: 2)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
        encoder.endEncoding()
        commandBuffer.commit()
        currentIndex = 1 - currentIndex
    }

    /// Remet les deux atlas à zéro.
    private func clearAtlases() {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        encoder.setComputePipelineState(clearPipeline)
        for atlas in atlases {
            encoder.setTexture(atlas, index: 0)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        currentIndex = 0
    }

    private var grid: MTLSize { MTLSize(width: Self.width, height: Self.height, depth: 1) }
    private var threads: MTLSize { MTLSize(width: 16, height: 16, depth: 1) }

    /// Atlas de couverture : `CloudLayer.maxCount` tranches équirectangulaires.
    /// Mono-canal **R8Unorm** (filtrable sur GPU iOS, contrairement à R32Float —
    /// l'atlas sera échantillonné en `filter::linear` par le raymarch).
    private static func makeAtlas(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = CloudLayer.maxCount
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}
