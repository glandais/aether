#if DEBUG
import SwiftUI

/// Badge FPS de profilage (DEBUG) — collé à gauche, centré verticalement.
/// Alimenté par `DebugHUD.shared` (posé par le Renderer). Ne capture pas les
/// gestes.
///
/// Vue à part (et non simple propriété calculée de `CanvasView`) : elle lit
/// `DebugHUD.shared.fps` dans **son** corps, si bien que l'écriture du FPS à
/// ~1 Hz ne réinvalide qu'elle, pas tout le canvas.
struct DebugFPSBadge: View {
    var body: some View {
        let hud = DebugHUD.shared
        let ms = hud.fps > 0 ? 1000.0 / hud.fps : 0
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(hud.fps, format: .number.precision(.fractionLength(0))) ips")
                .font(.system(.title3, design: .monospaced).bold())
            Text("\(ms, format: .number.precision(.fractionLength(1))) ms")
                .font(.system(.caption, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 6)
        .allowsHitTesting(false)
    }
}
#endif
