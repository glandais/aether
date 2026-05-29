import Testing
import simd
@testable import Aether

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
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.undo()
        #expect(model.canRedo)

        model.beginStroke(at: SIMD2(0.2, 0.2), camera: Self.testCamera)
        model.endStroke()
        #expect(!model.canRedo)
        #expect(model.strokes.count == 1)
    }

    @Test("L'effacement est annulable")
    func clearIsUndoable() {
        let model = CanvasModel()
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: Self.testCamera)
        model.endStroke()
        model.beginStroke(at: SIMD2(0.3, 0.3), camera: Self.testCamera)
        model.endStroke()
        #expect(model.strokes.count == 2)

        model.clear()
        #expect(model.strokes.isEmpty)

        model.undo()
        #expect(model.strokes.count == 2)
    }

    @Test("Un trait conserve la pose caméra du moment où il a été peint")
    func strokeRecordsCamera() {
        let model = CanvasModel()
        let camera = StrokeCamera(
            right: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0), forward: SIMD3(-1, 0, 0),
            tanHalfFov: 0.4, aspect: 1.5)
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: camera)
        model.endStroke()
        #expect(model.strokes.first?.camera == camera)
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
