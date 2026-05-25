import MetalKit
import SwiftUI

/// Pont SwiftUI ↔ `MTKView`. Le `Renderer` (delegate) est conservé par le
/// Coordinator pour vivre aussi longtemps que la vue.
struct MetalView: UIViewRepresentable {
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
        // Rien à pousser vers la vue tant que l'état de rendu est statique.
    }

    @MainActor
    final class Coordinator {
        var renderer: Renderer?
    }
}
