import CoreGraphics
import MetalKit
import SwiftUI

/// Pont SwiftUI ↔ `MTKView`. Le `Renderer` (delegate) est conservé par le
/// Coordinator pour vivre aussi longtemps que la vue. Le paysage et la depth
/// map ne sont (ré)appliqués que lorsque le contenu change (`contentID`) ;
/// les traits, le soleil et la météo sont poussés à chaque mise à jour.
struct MetalView: UIViewRepresentable {
    var strokes: [BrushStroke]
    var sunDirection: SIMD3<Float>
    var cloudParameters: CloudParameters
    var cameraTanHalfFov: Float
    var landscape: CGImage
    var depthMap: DepthMap?
    var contentID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        let renderer = Renderer(view: view)
        context.coordinator.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }

        if context.coordinator.appliedContentID != contentID {
            renderer.setLandscape(landscape)
            if let depthMap {
                renderer.setDepthMap(depthMap)
            }
            context.coordinator.appliedContentID = contentID
        }

        renderer.updateSunDirection(sunDirection)
        renderer.updateCloudParameters(cloudParameters)
        renderer.updateFieldOfView(cameraTanHalfFov)
        renderer.updateStrokes(strokes)
    }

    @MainActor
    final class Coordinator {
        var renderer: Renderer?
        var appliedContentID: UUID?
    }
}
