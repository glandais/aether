import SwiftUI

/// Panneau « More » : réglages contextuels (rares par geste) — ciel (centrer
/// soleil/lune, éphéméride), lieu (`PositionPanel`) et enregistrement du ciel en
/// fichier `.aether`. Les actions (fournies par `CanvasView`) referment d'abord
/// le panneau avant d'ouvrir une feuille ou de recadrer le regard.
///
/// Entrées étroites : des booléens d'activation, les entrées du sous-menu lieu
/// et des closures d'action — pas l'éclairage résolu ni le modèle.
struct MorePanel: View {
    /// Soleil / lune au-dessus de l'horizon (recentrage possible).
    let canCenterSun: Bool
    let canCenterMoon: Bool
    @Binding var dateOverride: Date?
    let defaultDay: Date
    let locationLabel: String
    let isResolvingHereNow: Bool
    let onCenterSun: () -> Void
    let onCenterMoon: () -> Void
    let onShowEphemeris: () -> Void
    let onPickLocation: () -> Void
    let onHereAndNow: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            HStack(spacing: 22) {
                PanelIconButton(
                    systemName: "sun.max", labelKey: "sky.centerSun", enabled: canCenterSun, action: onCenterSun)
                PanelIconButton(
                    systemName: "moon.stars", labelKey: "sky.centerMoon", enabled: canCenterMoon,
                    action: onCenterMoon)
                PanelIconButton(
                    systemName: "info.circle", labelKey: "ephemeris.title", enabled: true, action: onShowEphemeris)
            }
            Divider()
            PositionPanel(
                dateOverride: $dateOverride, defaultDay: defaultDay,
                locationLabel: locationLabel, isResolvingHereNow: isResolvingHereNow,
                onPickLocation: onPickLocation, onHereAndNow: onHereAndNow)
            Divider()
            // Enregistre l'état courant dans un fichier `.aether` (ciel
            // complet, autonome) — rechargeable depuis la galerie.
            Button(action: onSave) {
                Label(
                    String(localized: "action.save", table: "Aether"),
                    systemImage: "square.and.arrow.down"
                )
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        // Borne la largeur : sinon le Divider étire la carte sur toute la
        // largeur proposée (grand vide à gauche, surtout en paysage).
        .frame(width: 230)
    }
}

/// Bouton-icône des panneaux (ciel, lieu) : glyphe seul, atténué et inactif
/// quand indisponible.
struct PanelIconButton: View {
    let systemName: String
    let labelKey: String.LocalizationValue
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .accessibilityLabel(Text(String(localized: labelKey, table: "Aether")))
    }
}
