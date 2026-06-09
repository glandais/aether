import SwiftUI
import UniformTypeIdentifiers

/// Écran d'accueil : galerie de paysages curés, plus l'ouverture d'un ciel
/// enregistré (`.aether`). Chaque choix produit un `SceneContext` transmis via
/// `onSelect`, accompagné — pour un fichier rechargé — de l'état de canvas à
/// réappliquer (traits, regard, surcharges) ; `nil` pour un paysage curé neuf.
struct GalleryView: View {
    var onSelect: (SceneContext, RestoredCanvasState?) -> Void

    @State private var showImporter = false
    /// Échec d'ouverture présenté à l'utilisateur (`nil` = pas d'alerte). Distingue
    /// le fichier illisible du fichier d'une version antérieure d'Aether.
    @State private var openError: OpenError?

    /// Cas d'échec d'ouverture, chacun avec son message localisé sobre.
    private enum OpenError: Int, Identifiable {
        case unreadable
        case unsupportedVersion

        var id: Int { rawValue }

        var messageKey: String.LocalizationValue {
            switch self {
            case .unreadable: "gallery.openError"
            case .unsupportedVersion: "gallery.openErrorVersion"
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(CuratedLandscape.catalog) { landscape in
                        Button {
                            if let context = landscape.makeContext() {
                                onSelect(context, nil)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label(
                            String(localized: "gallery.open", table: "Aether"),
                            systemImage: "folder")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter, allowedContentTypes: [.aetherScene]
            ) { result in
                if case .success(let url) = result {
                    open(url)
                } else {
                    openError = .unreadable
                }
            }
            .alert(item: $openError) { error in
                Alert(title: Text(String(localized: error.messageKey, table: "Aether")))
            }
        }
    }

    /// Décode un fichier `.aether` et reconstruit la scène + l'état du canvas.
    /// L'URL est protégée (sandbox) : accès délimité le temps de la lecture.
    private func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let document = try AetherDocument.decode(from: data)
            guard let loaded = document.makeLoaded() else {
                openError = .unreadable
                return
            }
            onSelect(loaded.context, loaded.restored)
        } catch AetherDocumentError.unsupportedVersion {
            openError = .unsupportedVersion
        } catch {
            openError = .unreadable
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
