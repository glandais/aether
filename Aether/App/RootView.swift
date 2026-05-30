import SwiftUI

/// Navigation racine : la galerie (paysages curés + import photo) mène au
/// canvas de peinture plein écran pour le paysage choisi.
struct RootView: View {
    @State private var context: SceneContext?
    /// État de canvas à réappliquer quand la scène vient d'un fichier `.aether`
    /// rechargé ; `nil` pour un paysage curé neuf.
    @State private var restored: RestoredCanvasState?

    var body: some View {
        ZStack {
            if let context {
                CanvasView(context: context, restored: restored)
                    // Nouvelle scène (curée ou rechargée) = nouvelle identité :
                    // `@State` réamorcé proprement, sans fuite de l'état précédent.
                    .id(context.id)
                    .overlay(alignment: .topLeading) { backButton }
                    .transition(.opacity)
            } else {
                GalleryView { selected, restoredState in
                    restored = restoredState
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
