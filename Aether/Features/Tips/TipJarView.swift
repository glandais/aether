import StoreKit
import SwiftUI

/// L'écran des pourboires, poussé depuis « Soutenir Aether » dans la feuille
/// « À propos ».
///
/// Trois achats consommables qui ne débloquent rien. Les noms et les prix
/// viennent du store, dans la langue et la devise de l'acheteur : le catalogue
/// n'en porte aucun.
struct TipJarView: View {
    let tipJar: TipJar

    @Environment(\.purchase) private var purchase

    var body: some View {
        List {
            Section {
                if tipJar.isLoading && tipJar.products.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if tipJar.isUnavailable {
                    unavailable
                } else {
                    ForEach(tipJar.products) { product in
                        row(product)
                    }
                }
            } header: {
                Text("tip.header", tableName: "Aether")
                    .textCase(nil)
            } footer: {
                status
            }
        }
        .navigationTitle(Text("tip.title", tableName: "Aether"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await tipJar.load() }
    }

    private func row(_ product: Product) -> some View {
        Button {
            Task { await tipJar.buy(product, with: purchase) }
        } label: {
            HStack {
                Text(verbatim: product.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if tipJar.state == .purchasing(product.id) {
                    ProgressView()
                } else {
                    // Le prix vient du store, dans la devise de l'acheteur.
                    Text(verbatim: product.displayPrice)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(isPurchasing)
    }

    @ViewBuilder
    private var status: some View {
        switch tipJar.state {
        case .thanked:
            Label {
                Text("tip.thanks", tableName: "Aether")
            } icon: {
                Image(systemName: "heart.fill")
            }
            .foregroundStyle(.pink)
        case .pending:
            Text("tip.pending", tableName: "Aether")
        case .failed:
            Text("tip.failed", tableName: "Aether")
        case .idle, .purchasing:
            EmptyView()
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("tip.unavailable", tableName: "Aether")
                .foregroundStyle(.secondary)
            Button(String(localized: "tip.retry", table: "Aether")) {
                Task { await tipJar.load() }
            }
        }
    }

    private var isPurchasing: Bool {
        if case .purchasing = tipJar.state { true } else { false }
    }
}
