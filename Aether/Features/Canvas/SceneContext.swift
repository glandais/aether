import CoreGraphics
import Foundation

/// Tout ce dont le canvas a besoin pour peindre au-dessus d'un paysage donné :
/// la scène (lieu + instant), l'image de fond, et une depth map optionnelle
/// pour l'occlusion. Produit par la galerie curée ou l'import photo, consommé
/// par `CanvasView` → `Renderer`.
struct SceneContext: Identifiable {
    let id = UUID()
    var scene: Scene
    var landscape: CGImage
    var depthMap: DepthMap?
}
