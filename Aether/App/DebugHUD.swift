#if DEBUG
import Foundation

/// **Lecture FPS à l'écran — DEBUG/temporaire.**
///
/// Pont d'observation entre le `Renderer` (qui mesure les images par seconde,
/// cf. `Renderer.draw`) et un overlay SwiftUI, pour lire la perf *dans l'app* sur
/// device réel sans Console ni HUD Metal système. Échantillon partagé : le
/// raymarch n'a pas de référence vers la vue, et le câbler à travers les ~25
/// paramètres de `MetalView` ne vaut pas le coup. Compilé hors des builds
/// Release/App Store.
@Observable
@MainActor
final class DebugHUD {
    static let shared = DebugHUD()
    private init() {}

    /// Dernier FPS mesuré (fenêtre glissante d'une seconde, posé par le Renderer).
    var fps: Double = 0
}
#endif
