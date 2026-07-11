import SwiftUI

/// Curseur d'heure, encadré par deux bascules de défilement automatique
/// (recul / avance, mutuellement exclusives) : déplace le soleil/la lune, le
/// nuage se rallume.
///
/// Vue à part (et non fonction de `CanvasView`) pour resserrer la frontière
/// d'invalidation : elle ne lit que l'heure, le sens/vitesse de défilement et le
/// libellé — pas l'éclairage résolu ni les calques.
struct TimeBar: View {
    @Binding var hour: Double
    let isDaytime: Bool
    let timeLabel: String
    @Binding var autoPlay: AutoPlay
    @Binding var autoPlaySpeed: Int

    /// Multiplicateurs de vitesse disponibles (cycliques). 1× = 0,25 h/s.
    private static let autoPlaySpeeds = [1, 2, 4, 8, 16]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isDaytime ? "sun.max" : "moon.stars")
                .font(.footnote)
                .foregroundStyle(.secondary)
            autoPlayButton(.backward, icon: "backward.fill", label: "time.rewind")
            Slider(value: $hour, in: 0...24)
                .tint(.white.opacity(0.55))
            autoPlayButton(.forward, icon: "forward.fill", label: "time.advance")
            speedButton
            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        // Cape la largeur : en paysage le curseur resterait sinon collé aux bords.
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
    }

    /// Bascule de défilement automatique (recul ou avance). Réactiver le même
    /// sens l'arrête ; activer l'autre bascule de sens (exclusion mutuelle).
    private func autoPlayButton(
        _ mode: AutoPlay, icon: String, label: String.LocalizationValue
    ) -> some View {
        Button {
            autoPlay = (autoPlay == mode) ? .none : mode
        } label: {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(autoPlay == mode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: label, table: "Aether")))
    }

    /// Règle la vitesse de défilement : cycle 1× → 2× → 4× → 8× → 16× → 1×.
    private var speedButton: some View {
        Button {
            let speeds = Self.autoPlaySpeeds
            let index = speeds.firstIndex(of: autoPlaySpeed) ?? 0
            autoPlaySpeed = speeds[(index + 1) % speeds.count]
        } label: {
            Text(verbatim: "\(autoPlaySpeed)×")
                .font(.caption.monospacedDigit())
                .foregroundStyle(autoPlay == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 30, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "time.speed", table: "Aether")))
        .accessibilityValue(Text(verbatim: "\(autoPlaySpeed)×"))
    }
}
