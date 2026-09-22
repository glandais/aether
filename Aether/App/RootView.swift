import SwiftUI

/// Navigation racine : la galerie (paysages curés + import photo) mène au
/// canvas de peinture plein écran pour le paysage choisi.
struct RootView: View {
    @State private var context: SceneContext?
    /// État de canvas à réappliquer quand la scène vient d'un fichier `.aether`
    /// rechargé ; `nil` pour un paysage curé neuf.
    @State private var restored: RestoredCanvasState?
    /// Modèle de peinture de la scène ouverte, construit **une seule fois** à
    /// l'ouverture (cf. `open`) et conservé ici : les ré-inits de `CanvasView`
    /// ne le reconstruisent pas.
    @State private var canvasModel: CanvasModel?
    /// Interface masquée (harnais de capture) : canvas plein écran sans chrome.
    @State private var chromeHidden = false

    var body: some View {
        ZStack {
            if let context, let canvasModel {
                CanvasView(
                    context: context, model: canvasModel,
                    restored: restored, chromeHidden: chromeHidden)
                    // Nouvelle scène (curée ou rechargée) = nouvelle identité :
                    // `@State` réamorcé proprement, sans fuite de l'état précédent.
                    .id(context.id)
                    .overlay(alignment: .topLeading) { if !chromeHidden { backButton } }
                    .transition(.opacity)
            } else {
                GalleryView { selected, restoredState in
                    open(selected, restored: restoredState)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: context?.id)
        // Harnais de capture (DEBUG uniquement) : démarre directement sur une
        // scène injectée si la variable d'environnement AETHER_SHOT est posée.
        // Compilé hors des builds Release/App Store.
        #if DEBUG
        .onAppear {
            if context == nil, let setup = ScreenshotHarness.setupFromEnvironment() {
                chromeHidden = setup.chromeHidden
                open(setup.context, restored: setup.restored)
            }
        }
        #endif
    }

    /// Ouvre une scène (curée ou rechargée) : son modèle est construit ici, une
    /// fois, avant de basculer sur le canvas.
    private func open(_ selected: SceneContext, restored restoredState: RestoredCanvasState?) {
        restored = restoredState
        canvasModel = CanvasModel(context: selected, restored: restoredState)
        context = selected
    }

    private var backButton: some View {
        Button {
            context = nil
            canvasModel = nil
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
