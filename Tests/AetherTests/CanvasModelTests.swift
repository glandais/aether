import Testing
import Foundation
import simd
@testable import Aether

/// Tous les traits du modèle, aplatis — l'app n'expose plus que `hasStrokes`
/// (pas d'allocation par évaluation de body) ; les tests gardent la vue à plat
/// pour compter les traits à travers les calques.
extension CanvasModel {
    var allStrokes: [BrushStroke] { layers.flatMap(\.strokes) }
}

/// Valide l'historique annuler/rétablir du canvas (granularité : un trait).
@MainActor
struct CanvasModelTests {
    /// Pose caméra factice pour les traits de test (base identité).
    private static let testCamera = StrokeCamera(
        right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, -1),
        tanHalfFov: 0.5, aspect: 1)

    @Test("Un trait achevé est annulable puis rétablissable")
    func undoRedoStroke() {
        let model = CanvasModel()
        #expect(!model.canUndo)

        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.extendStroke(to: SIMD2(0.6, 0.5))
        model.endStroke()
        #expect(model.allStrokes.count == 1)
        #expect(model.canUndo)
        #expect(!model.canRedo)

        model.undo()
        #expect(model.allStrokes.isEmpty)
        #expect(model.canRedo)

        model.redo()
        #expect(model.allStrokes.count == 1)
        #expect(!model.canRedo)
    }

    @Test("Un nouveau trait après annulation purge la pile de rétablissement")
    func newStrokeClearsRedo() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.undo()
        #expect(model.canRedo)

        model.beginStroke(at: SIMD2(0.2, 0.2), camera: Self.testCamera)
        model.endStroke()
        #expect(!model.canRedo)
        #expect(model.allStrokes.count == 1)
    }

    @Test("L'effacement est annulable")
    func clearIsUndoable() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.beginStroke(at: SIMD2(0.3, 0.3), camera: Self.testCamera)
        model.endStroke()
        #expect(model.allStrokes.count == 2)

        model.clear()
        #expect(model.allStrokes.isEmpty)

        model.undo()
        #expect(model.allStrokes.count == 2)
    }

    @Test("Un trait conserve la pose caméra du moment où il a été peint")
    func strokeRecordsCamera() {
        let model = CanvasModel()
        let camera = StrokeCamera(
            right: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0), forward: SIMD3(-1, 0, 0),
            tanHalfFov: 0.4, aspect: 1.5)
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: camera)
        model.endStroke()
        #expect(model.allStrokes.first?.camera == camera)
    }

    @Test("Le tangage est clampé, le lacet est libre")
    func rotationClampsPitchNotYaw() {
        let model = CanvasModel()
        model.setRotation(yaw: 12, pitch: 5)
        #expect(model.viewYaw == 12)  // lacet libre (panoramique)
        #expect(model.viewPitch < 1.5)  // clampé sous ~80°

        model.setRotation(yaw: -8, pitch: -5)
        #expect(model.viewPitch > -1.5)
    }

    // MARK: - Calques (un par étage / genre)

    @Test("Peindre sans changer de genre reste dans un seul calque")
    func sameGenusKeepsSingleLayer() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.beginStroke(at: SIMD2(0.2, 0.2), camera: Self.testCamera)
        model.endStroke()
        #expect(model.layers.count == 1)
        #expect(model.layers.first?.genus == .cumulus)  // défaut
        #expect(model.layers.first?.strokes.count == 2)
    }

    @Test("Changer de genre ouvre un nouveau calque à cet étage")
    func changedGenusOpensNewLayer() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.selectGenus(.cirrus)
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        #expect(model.layers.count == 2)
        #expect(model.layer(for: .cirrus)?.strokes.count == 1)
        #expect(model.layer(for: .cumulus)?.strokes.count == 1)
    }

    @Test("Repeindre un genre déjà peint réutilise son calque")
    func returningToGenusReusesLayer() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.selectGenus(.cirrus)
        model.beginStroke(at: SIMD2(0.4, 0.4), camera: Self.testCamera)
        model.endStroke()
        model.selectGenus(.cumulus)
        model.beginStroke(at: SIMD2(0.3, 0.3), camera: Self.testCamera)
        model.endStroke()
        #expect(model.layers.count == 2)
        #expect(model.layer(for: .cumulus)?.strokes.count == 2)
    }

    @Test("Annuler un trait qui a créé un calque retire ce calque")
    func undoRemovesNewLayer() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.selectGenus(.altocumulus)
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        #expect(model.layers.count == 2)

        model.undo()
        #expect(model.layers.count == 1)
        #expect(model.layers.first?.genus == .cumulus)
    }

    @Test("Basculer la visibilité d'un calque est annulable")
    func toggleVisibilityIsUndoable() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        #expect(model.layer(for: .cumulus)?.isVisible == true)

        model.setVisible(false, for: .cumulus)
        #expect(model.layer(for: .cumulus)?.isVisible == false)

        model.undo()
        #expect(model.layer(for: .cumulus)?.isVisible == true)
    }
}
