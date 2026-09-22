import SwiftUI

/// Sous-menu « lieu » du panneau « More » : date du jour (saison, phase lunaire,
/// ciel étoilé), coordonnée courante, ouverture de la carte, et « ici &
/// maintenant » (recale lieu, jour et heure sur l'instant courant).
///
/// Entrées étroites : la surcharge de jour (liée), son défaut, le libellé de
/// lieu déjà formaté et l'état de résolution GPS ; les actions sont fournies par
/// `CanvasView`.
struct PositionPanel: View {
    /// Jour choisi, ancré à midi UTC. `nil` = jour local d'origine de la scène.
    @Binding var dateOverride: Date?
    /// Jour d'origine de la scène (midi UTC), montré tant qu'aucun n'est choisi.
    let defaultDay: Date
    /// Coordonnée effective compacte, ex. « 48.9°N, 2.4°E ».
    let locationLabel: String
    /// Résolution « ici & maintenant » en cours (position GPS + fuseau).
    let isResolvingHereNow: Bool
    let onPickLocation: () -> Void
    let onHereAndNow: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DatePicker(
                    "", selection: $dateOverride[orDefault: defaultDay], displayedComponents: .date
                )
                .labelsHidden()
                .environment(\.timeZone, .gmt)
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .accessibilityLabel(Text(String(localized: "time.date", table: "Aether")))
            }

            Text(locationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 22) {
                PanelIconButton(systemName: "map", labelKey: "location.title", enabled: true, action: onPickLocation)
                Button(action: onHereAndNow) {
                    Group {
                        if isResolvingHereNow {
                            ProgressView()
                        } else {
                            Image(systemName: "scope").font(.body)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .disabled(isResolvingHereNow)
                .accessibilityLabel(Text(String(localized: "location.hereNow", table: "Aether")))
            }
        }
    }
}
