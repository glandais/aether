import Observation
import simd

/// État du canvas de peinture : les traits de pinceau déjà tracés, exprimés en
/// coordonnées normalisées [0,1]² (origine en haut à gauche). Type d'UI ; le
/// rendu consomme `strokes` (modèles `BrushStroke` du Domain).
@MainActor
@Observable
final class CanvasModel {
    private(set) var strokes: [BrushStroke] = []
    private(set) var isDrawing = false

    /// Rayon et adoucissement du pinceau, en coordonnées normalisées.
    var brushRadius: Float = 0.08
    var brushSoftness: Float = 0.55

    /// Distance minimale entre deux points d'un même trait (décimation).
    private let minSpacing: Float = 0.012

    func beginStroke(at point: SIMD2<Float>) {
        strokes.append(BrushStroke(points: [point], radius: brushRadius, softness: brushSoftness))
        isDrawing = true
    }

    func extendStroke(to point: SIMD2<Float>) {
        guard var stroke = strokes.last else { return }
        if let last = stroke.points.last, distance(last, point) < minSpacing {
            return
        }
        stroke.points.append(point)
        strokes[strokes.count - 1] = stroke
    }

    func endStroke() {
        isDrawing = false
    }

    func clear() {
        strokes = []
        isDrawing = false
    }
}
