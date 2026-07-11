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
    private enum OpenError: Error {
        case unreadable
        case unsupportedVersion

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
            .alert(
                openErrorMessage,
                isPresented: isShowingOpenError
            ) {
                // Aucune action explicite : le système ajoute un bouton de
                // fermeture par défaut, comme l'ancien `Alert(title:)`.
            }
        }
    }

    /// Titre de l'alerte : message localisé de l'échec courant (chaîne vide quand
    /// aucune alerte n'est présentée — le titre n'est alors pas affiché).
    private var openErrorMessage: String {
        openError.map { String(localized: $0.messageKey, table: "Aether") } ?? ""
    }

    /// Passerelle `Bool` pilotant la présentation de l'alerte depuis `openError` :
    /// la fermeture (système) remet l'échec à `nil`.
    private var isShowingOpenError: Binding<Bool> {
        Binding(
            get: { openError != nil },
            set: { presented in
                if !presented { openError = nil }
            }
        )
    }

    /// Décode un fichier `.aether` et reconstruit la scène + l'état du canvas. La
    /// lecture s'effectue hors de l'acteur principal (cf. `load(_:)`) ; seul le
    /// résultat (sélection ou échec) est appliqué sur le fil principal.
    private func open(_ url: URL) {
        Task {
            switch await Self.load(url) {
            case .success(let loaded):
                onSelect(loaded.context, loaded.restored)
            case .failure(let error):
                openError = error
            }
        }
    }

    /// Lit et décode le fichier `.aether` **hors de l'acteur principal** : un
    /// fichier iCloud Drive non téléchargé peut bloquer longtemps, ce qui figerait
    /// l'UI si la lecture se faisait sur le fil principal. L'accès sandbox encadre
    /// la lecture dans ce même contexte d'exécution. Renvoie l'échec typé le cas
    /// échéant (illisible vs version incompatible), identique à l'ancien code.
    private nonisolated static func load(_ url: URL) async -> sending Result<LoadedScene, OpenError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let document = try AetherDocument.decode(from: data)
            guard let loaded = document.makeLoaded() else {
                return .failure(.unreadable)
            }
            return .success(loaded)
        } catch AetherDocumentError.unsupportedVersion {
            return .failure(.unsupportedVersion)
        } catch {
            return .failure(.unreadable)
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
