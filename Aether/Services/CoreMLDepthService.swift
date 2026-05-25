import CoreGraphics
import CoreImage
import CoreML
import CoreVideo

/// Implémentation de `DepthService` via le modèle CoreML Depth Anything V2
/// (Small, F16). Estime une profondeur monoculaire relative pour les photos
/// sans LiDAR. Acteur : l'inférence et le cache du modèle sont sérialisés.
actor CoreMLDepthService: DepthService {
    enum ServiceError: Error {
        case pixelBufferCreationFailed
        case emptyDepthOutput
    }

    private var model: DepthAnythingV2SmallF16?
    private let context = CIContext()
    // Le modèle étire l'entrée à cette taille (cf. conversion DepthWeaver).
    private let inputWidth = 518
    private let inputHeight = 392

    func estimateDepth(for image: CGImage) async throws -> DepthMap {
        let model = try loadModel()

        guard let inputBuffer = Self.makePixelBuffer(width: inputWidth, height: inputHeight) else {
            throw ServiceError.pixelBufferCreationFailed
        }
        let source = CIImage(cgImage: image)
        let scaleX = CGFloat(inputWidth) / source.extent.width
        let scaleY = CGFloat(inputHeight) / source.extent.height
        let resized = source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        context.render(resized, to: inputBuffer)

        let depthBuffer = try model.prediction(image: inputBuffer).depth
        return try Self.makeDepthMap(from: depthBuffer)
    }

    private func loadModel() throws -> DepthAnythingV2SmallF16 {
        if let model {
            return model
        }
        let configuration = MLModelConfiguration()
        let loaded = try DepthAnythingV2SmallF16(configuration: configuration)
        model = loaded
        return loaded
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    /// Lit le buffer de profondeur (Float16), normalise en [0,1] et convertit
    /// dans la convention du Domain : 0 = proche, 1 = lointain. Depth Anything
    /// sort une profondeur inverse (proche = grand), d'où l'inversion finale.
    private static func makeDepthMap(from buffer: CVPixelBuffer) throws -> DepthMap {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else {
            throw ServiceError.emptyDepthOutput
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ServiceError.emptyDepthOutput
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let halfsPerRow = bytesPerRow / MemoryLayout<Float16>.size
        let pointer = base.assumingMemoryBound(to: Float16.self)

        var raw = [Float](repeating: 0, count: width * height)
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        for y in 0..<height {
            for x in 0..<width {
                let value = Float(pointer[y * halfsPerRow + x])
                raw[y * width + x] = value
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
            }
        }

        let range = max(maxValue - minValue, 1e-5)
        // Normalisé : proche = 1 (sortie inverse) → on inverse pour 0 = proche.
        let values = raw.map { 1.0 - ($0 - minValue) / range }
        return DepthMap(width: width, height: height, values: values)
    }
}
