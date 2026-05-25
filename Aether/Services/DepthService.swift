import CoreGraphics

/// Estimation de profondeur d'une photo, pour l'occlusion des nuages par le
/// relief. Implémentations prévues : CoreML Depth Anything (photos sans LiDAR)
/// ou ARKit scene depth (photos prises avec LiDAR).
protocol DepthService: Sendable {
    func estimateDepth(for image: CGImage) async throws -> DepthMap
}
