import Observation
import simd

/// État du canvas de peinture : les traits de pinceau déjà tracés, exprimés en
/// coordonnées normalisées [0,1]² (origine en haut à gauche). Type d'UI ; le
/// rendu consomme `strokes` (modèles `BrushStroke` du Domain).
///
/// Historique annuler/rétablir à la granularité du trait : chaque trait achevé
/// (et chaque effacement) est une action réversible. Le `Renderer` repeint
/// automatiquement (sa mise à jour incrémentale gère l'ajout comme le retrait).
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

    /// Piles d'historique : instantanés de l'état `strokes`.
    private var undoStack: [[BrushStroke]] = []
    private var redoStack: [[BrushStroke]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func beginStroke(at point: SIMD2<Float>) {
        recordHistory()  // instantané d'avant-trait : l'annulation y revient
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
        guard !strokes.isEmpty else { return }
        recordHistory()
        strokes = []
        isDrawing = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(strokes)
        strokes = previous
        isDrawing = false
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(strokes)
        strokes = next
        isDrawing = false
    }

    /// Empile l'état courant et invalide la pile de rétablissement (nouvelle
    /// branche d'historique).
    private func recordHistory() {
        undoStack.append(strokes)
        redoStack.removeAll()
    }
}
