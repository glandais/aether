import Testing
import simd
@testable import Aether

/// Valide l'historique annuler/rétablir du canvas (granularité : un trait).
@MainActor
struct CanvasModelTests {
    @Test("Un trait achevé est annulable puis rétablissable")
    func undoRedoStroke() {
        let model = CanvasModel()
        #expect(!model.canUndo)

        model.beginStroke(at: SIMD2(0.5, 0.5))
        model.extendStroke(to: SIMD2(0.6, 0.5))
        model.endStroke()
        #expect(model.strokes.count == 1)
        #expect(model.canUndo)
        #expect(!model.canRedo)

        model.undo()
        #expect(model.strokes.isEmpty)
        #expect(model.canRedo)

        model.redo()
        #expect(model.strokes.count == 1)
        #expect(!model.canRedo)
    }

    @Test("Un nouveau trait après annulation purge la pile de rétablissement")
    func newStrokeClearsRedo() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5))
        model.endStroke()
        model.undo()
        #expect(model.canRedo)

        model.beginStroke(at: SIMD2(0.2, 0.2))
        model.endStroke()
        #expect(!model.canRedo)
        #expect(model.strokes.count == 1)
    }

    @Test("L'effacement est annulable")
    func clearIsUndoable() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5))
        model.endStroke()
        model.beginStroke(at: SIMD2(0.3, 0.3))
        model.endStroke()
        #expect(model.strokes.count == 2)

        model.clear()
        #expect(model.strokes.isEmpty)

        model.undo()
        #expect(model.strokes.count == 2)
    }

    @Test("Un mouvement de caméra (rotation/zoom) efface traits et historique")
    func clearForCameraChangeResets() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5))
        model.endStroke()
        model.undo()  // alimente la pile de rétablissement
        #expect(model.canRedo)

        model.clearForCameraChange()
        #expect(model.strokes.isEmpty)
        #expect(!model.canUndo)
        #expect(!model.canRedo)
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
}
