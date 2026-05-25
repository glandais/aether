import MetalKit
import SwiftUI

/// Pont SwiftUI ↔ `MTKView`. Le `Renderer` (delegate) est conservé par le
/// Coordinator pour vivre aussi longtemps que la vue. Les traits de pinceau
/// sont poussés vers le `Renderer` à chaque mise à jour SwiftUI.
struct MetalView: UIViewRepresentable {
    var strokes: [BrushStroke]

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
        context.coordinator.renderer?.updateStrokes(strokes)
    }

    @MainActor
    final class Coordinator {
        var renderer: Renderer?
    }
}
