import SwiftUI

/// Hôte plein écran du canvas de rendu volumétrique.
/// Étape 1 : un `MTKView` qui efface l'écran avec une couleur atmosphérique.
struct CanvasView: View {
    var body: some View {
        MetalView()
            .ignoresSafeArea()
    }
}
