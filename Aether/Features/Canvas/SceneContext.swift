import CoreGraphics
import Foundation

/// Tout ce dont le canvas a besoin pour peindre au-dessus d'un paysage donné :
/// la scène (lieu + instant), l'image de fond, et une depth map optionnelle
/// pour l'occlusion. Produit par la galerie curée, consommé par
/// `CanvasView` → `Renderer`.
struct SceneContext: Identifiable {
    let id = UUID()
    var scene: Scene
    var landscape: CGImage
    var depthMap: DepthMap?
    /// Aspect (largeur/hauteur) auquel afficher le paysage sans déformation
    /// (lettrage). `nil` = plein cadre (paysages curés procéduraux abstraits).
    var displayAspect: CGFloat?
    /// Exposition du paysage (≈ luminance, 0…1) : sert à caler la luminosité du
    /// nuage sur celle du paysage (point blanc). Défaut neutre.
    var skyExposure: Float = 0.6
    /// Paramètres de rendu dérivés de la météo statique du paysage curé.
    var cloudParameters: CloudParameters = .neutral
}
