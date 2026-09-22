import SwiftUI

/// Liens externes de l'app, réunis en un seul endroit. Ouvrir l'un d'eux passe
/// la main à Safari ou à l'App Store : l'app elle-même n'émet aucune requête.
enum AppLinks {
    // Force-unwrap justifié : littéraux constants valides, l'initialiseur ne
    // peut échouer ici.
    static let website = URL(string: "https://glandais.github.io/aether/")!
    static let support = URL(string: "https://glandais.github.io/aether/support/")!
    static let privacy = URL(string: "https://glandais.github.io/aether/privacy/")!
    static let sourceCode = URL(string: "https://github.com/glandais/aether")!
    static let writeReview = URL(string: "https://apps.apple.com/app/id6773940359?action=write-review")!
    static let developerApps = URL(string: "https://apps.apple.com/developer/id1891310404")!
}

/// Feuille « À propos » discrète, ouverte depuis la galerie : version de l'app
/// et liens vers le site, le support, la confidentialité, le code source et
/// l'App Store.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("about.website", systemImage: "globe", url: AppLinks.website)
                    row("about.support", systemImage: "questionmark.circle", url: AppLinks.support)
                    row("about.privacy", systemImage: "hand.raised", url: AppLinks.privacy)
                    row("about.source", systemImage: "chevron.left.forwardslash.chevron.right",
                        url: AppLinks.sourceCode)
                }
                Section {
                    row("about.rate", systemImage: "star", url: AppLinks.writeReview)
                    row("about.moreApps", systemImage: "square.grid.2x2", url: AppLinks.developerApps)
                } footer: {
                    if let version {
                        Text(version)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                }
            }
            .navigationTitle(Text("about.title", tableName: "Aether"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.done", table: "Aether")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func row(_ key: String.LocalizationValue, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            Label(String(localized: key, table: "Aether"), systemImage: systemImage)
        }
    }

    /// « Aether 1.0.5 (6) », lu dans l'Info.plist du bundle.
    private var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Aether \(short) (\($0))" } ?? "Aether \(short)"
    }
}
