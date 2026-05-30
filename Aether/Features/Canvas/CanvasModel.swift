import Observation
import simd

/// État du canvas de peinture : les **cubes** de nuage déjà peints. Chaque cube
/// est ancré sur une direction de regard et porte ses traits (en coordonnées
/// normalisées [0,1]², origine en haut à gauche). Le rendu consomme `cubes`.
///
/// Plusieurs cubes : il existe toujours un **cube courant** (le dernier). Tout
/// trait y est ajouté. Quand le regard a changé depuis la création du cube
/// courant, le prochain trait ouvre un **nouveau** cube ancré sur le regard
/// courant (qui devient le cube courant) ; on ne revient jamais dans un cube
/// antérieur.
///
/// Historique annuler/rétablir à la granularité du trait : chaque trait achevé
/// (et chaque effacement) est une action réversible — on instantané la liste de
/// cubes. Le `Renderer` repeint automatiquement (mise à jour incrémentale par
/// cube : ajout comme retrait).
@MainActor
@Observable
final class CanvasModel {
    private(set) var cubes: [CloudCube] = []
    private(set) var isDrawing = false

    /// Rayon et adoucissement du pinceau, en coordonnées normalisées.
    var brushRadius: Float = 0.08
    var brushSoftness: Float = 0.55

    /// Mode rotation du regard : quand actif, le drag pivote la vue au lieu de
    /// peindre. Piloté par le bouton « Pivoter la vue ».
    var isRotating = false

    /// Orientation du regard (radians) : lacet (libre) + tangage (clampé).
    private(set) var viewYaw: Float = 0
    private(set) var viewPitch: Float = 0

    /// Limite de tangage (~80°) : empêche la bascule du regard.
    private static let maxPitch: Float = 1.4

    /// Distance minimale entre deux points d'un même trait (décimation).
    private let minSpacing: Float = 0.012

    /// Au-delà de ce cosinus d'écart angulaire entre deux regards, on les
    /// considère identiques (même cube). Les deux regards sont alors bit-à-bit
    /// égaux en pratique ; la marge absorbe le bruit flottant.
    private static let sameViewCos: Float = 0.99999

    /// Piles d'historique : instantanés de l'état `cubes`.
    private var undoStack: [[CloudCube]] = []
    private var redoStack: [[CloudCube]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Tous les traits, aplatis (lecture seule) : pour l'état d'édition de l'UI
    /// (y a-t-il à effacer ?). Un cube porte toujours ≥ 1 trait, donc
    /// `!cubes.isEmpty` suffit aussi.
    var strokes: [BrushStroke] { cubes.flatMap(\.strokes) }

    func beginStroke(at point: SIMD2<Float>, camera: StrokeCamera) {
        recordHistory()  // instantané d'avant-trait : l'annulation y revient
        let stroke = BrushStroke(
            points: [point], radius: brushRadius, softness: brushSoftness, camera: camera)
        // Le regard a-t-il changé depuis la création du cube courant ? Si oui (ou
        // s'il n'y a pas encore de cube), on ouvre un nouveau cube ancré sur le
        // regard courant — sauf au plafond, où l'on reste dans le cube courant.
        let sameView = cubes.last.map {
            dot($0.anchorForward, camera.forward) > Self.sameViewCos
        } ?? false
        if !sameView && cubes.count < CloudCube.maxCount {
            cubes.append(CloudCube(anchorForward: camera.forward, strokes: [stroke]))
        } else {
            // Cube courant : même regard, ou plafond atteint (repli sans perte).
            cubes[cubes.count - 1].strokes.append(stroke)
        }
        isDrawing = true
    }

    func extendStroke(to point: SIMD2<Float>) {
        guard let ci = cubes.indices.last,
              var stroke = cubes[ci].strokes.last else { return }
        if let last = stroke.points.last, distance(last, point) < minSpacing {
            return
        }
        stroke.points.append(point)
        cubes[ci].strokes[cubes[ci].strokes.count - 1] = stroke
    }

    func endStroke() {
        isDrawing = false
    }

    func clear() {
        guard !cubes.isEmpty else { return }
        recordHistory()
        cubes = []
        isDrawing = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(cubes)
        cubes = previous
        isDrawing = false
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(cubes)
        cubes = next
        isDrawing = false
    }

    /// Réamorce l'état depuis un fichier `.aether` rechargé : remplace les cubes
    /// et l'orientation, réinitialise l'historique (pas d'annulation à travers un
    /// chargement). Le tangage est reclampé par sécurité.
    func load(
        cubes: [CloudCube], viewYaw: Float, viewPitch: Float,
        brushRadius: Float, brushSoftness: Float
    ) {
        self.cubes = cubes
        self.viewYaw = viewYaw
        self.viewPitch = min(max(viewPitch, -Self.maxPitch), Self.maxPitch)
        self.brushRadius = brushRadius
        self.brushSoftness = brushSoftness
        isDrawing = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Oriente le regard. Le lacet est libre (panoramique) ; le tangage est
    /// clampé à ±`maxPitch` pour éviter la bascule.
    func setRotation(yaw: Float, pitch: Float) {
        viewYaw = yaw
        viewPitch = min(max(pitch, -Self.maxPitch), Self.maxPitch)
    }

    /// Empile l'état courant et invalide la pile de rétablissement (nouvelle
    /// branche d'historique).
    private func recordHistory() {
        undoStack.append(cubes)
        redoStack.removeAll()
    }
}
