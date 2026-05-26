import SwiftUI

/// Écran d'accueil : galerie de paysages curés.
/// Chaque choix produit un `SceneContext` transmis via `onSelect`.
struct GalleryView: View {
    var onSelect: (SceneContext) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(CuratedLandscape.catalog) { landscape in
                        Button {
                            if let context = landscape.makeContext() {
                                onSelect(context)
                            }
                        } label: {
                            LandscapeThumbnail(landscape: landscape)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Aether")
        }
    }
}

/// Vignette d'un paysage curé : dégradé de la palette + titre sobre.
private struct LandscapeThumbnail: View {
    let landscape: CuratedLandscape

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(
                LinearGradient(
                    colors: [
                        Color(cgColor: landscape.palette.skyHigh),
                        Color(cgColor: landscape.palette.skyLow),
                        Color(cgColor: landscape.palette.horizon),
                        Color(cgColor: landscape.palette.ground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 150)
            .overlay(alignment: .bottomLeading) {
                Text(landscape.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(10)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.08))
            )
    }
}
