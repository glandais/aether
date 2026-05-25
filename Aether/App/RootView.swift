import SwiftUI

/// Navigation racine : la galerie (paysages curés + import photo) mène au
/// canvas de peinture plein écran pour le paysage choisi.
struct RootView: View {
    @State private var context: SceneContext?

    var body: some View {
        ZStack {
            if let context {
                CanvasView(context: context)
                    .overlay(alignment: .topLeading) { backButton }
                    .transition(.opacity)
            } else {
                GalleryView { selected in
                    context = selected
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: context?.id)
    }

    private var backButton: some View {
        Button {
            context = nil
        } label: {
            Image(systemName: "chevron.left")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.top, 8)
    }
}
