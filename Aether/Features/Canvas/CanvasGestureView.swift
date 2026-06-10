import SwiftUI
import UIKit

/// Couche de gestes UIKit posée au-dessus du `MetalView`. SwiftUI ne distingue
/// pas le nombre de doigts d'un `DragGesture` et n'offre aucun « two-finger pan »
/// ; pour le comportement iPhone standard — un doigt peint (ou pivote en mode
/// regard), deux doigts pilotent toujours la caméra (glissement → rotation,
/// pincement → zoom, simultanément) — on s'appuie sur des `UIGestureRecognizer`
/// aux limites de doigts explicites.
///
/// La vue ne fait que router les états des reconnaisseurs vers des closures :
/// toute la logique (peinture, ancre de rotation, FOV) reste dans `CanvasView`.
/// Les `bounds` de la `UIView` valent exactement le cadre rendu (lettré ou plein
/// écran), comme le `GeometryReader` qu'elle remplace.
struct CanvasGestureView: UIViewRepresentable {
    /// Mode rotation du regard : pilote la branche du **pan à un doigt**
    /// (peindre vs pivoter). Les gestes à deux doigts pilotent la caméra dans les
    /// deux modes.
    var isRotating: Bool

    var onPaintBegan: (CGPoint, CGSize) -> Void
    var onPaintMoved: (CGPoint, CGSize) -> Void
    var onPaintEnded: () -> Void
    /// Un second doigt s'est posé pendant le trait : l'amorce est annulée.
    var onPaintCancelled: () -> Void

    var onRotateBegan: () -> Void
    var onRotateChanged: (CGSize, CGSize) -> Void
    var onRotateEnded: () -> Void

    var onZoomBegan: () -> Void
    var onZoomChanged: (CGFloat) -> Void
    var onZoomEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let coordinator = context.coordinator
        coordinator.view = view

        // Pan 1 doigt : peinture (ou rotation en mode regard). `max = 1` assure
        // la transition propre — un 2ᵉ doigt fait passer ce reconnaisseur en
        // `.cancelled` tout seul, ce qui annule l'amorce de trait.
        let onePan = UIPanGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleOnePan))
        onePan.minimumNumberOfTouches = 1
        onePan.maximumNumberOfTouches = 1
        onePan.delegate = coordinator
        view.addGestureRecognizer(onePan)

        // Pan 2 doigts : toujours rotation caméra (« scroll »).
        let twoPan = UIPanGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleTwoPan))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.delegate = coordinator
        view.addGestureRecognizer(twoPan)

        // Pincement : toujours zoom FOV, simultané au pan 2 doigts.
        let pinch = UIPinchGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handlePinch))
        pinch.delegate = coordinator
        view.addGestureRecognizer(pinch)

        coordinator.twoPan = twoPan
        coordinator.pinch = pinch
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Réassigner à chaque mise à jour : les closures capturent l'état SwiftUI
        // courant (ancre de rotation, FOV…), qui change entre rendus.
        let coordinator = context.coordinator
        coordinator.isRotating = isRotating
        coordinator.onPaintBegan = onPaintBegan
        coordinator.onPaintMoved = onPaintMoved
        coordinator.onPaintEnded = onPaintEnded
        coordinator.onPaintCancelled = onPaintCancelled
        coordinator.onRotateBegan = onRotateBegan
        coordinator.onRotateChanged = onRotateChanged
        coordinator.onRotateEnded = onRotateEnded
        coordinator.onZoomBegan = onZoomBegan
        coordinator.onZoomChanged = onZoomChanged
        coordinator.onZoomEnded = onZoomEnded
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: UIView?
        weak var twoPan: UIPanGestureRecognizer?
        weak var pinch: UIPinchGestureRecognizer?

        var isRotating = false

        var onPaintBegan: (CGPoint, CGSize) -> Void = { _, _ in }
        var onPaintMoved: (CGPoint, CGSize) -> Void = { _, _ in }
        var onPaintEnded: () -> Void = {}
        var onPaintCancelled: () -> Void = {}
        var onRotateBegan: () -> Void = {}
        var onRotateChanged: (CGSize, CGSize) -> Void = { _, _ in }
        var onRotateEnded: () -> Void = {}
        var onZoomBegan: () -> Void = {}
        var onZoomChanged: (CGFloat) -> Void = { _ in }
        var onZoomEnded: () -> Void = {}

        private var size: CGSize { view?.bounds.size ?? .zero }

        @objc func handleOnePan(_ recognizer: UIPanGestureRecognizer) {
            let size = self.size
            switch recognizer.state {
            case .began:
                if isRotating { onRotateBegan() } else {
                    onPaintBegan(recognizer.location(in: view), size)
                }
            case .changed:
                if isRotating {
                    onRotateChanged(translation(recognizer), size)
                } else {
                    onPaintMoved(recognizer.location(in: view), size)
                }
            case .ended:
                if isRotating { onRotateEnded() } else { onPaintEnded() }
            case .cancelled, .failed:
                // Annulé par l'arrivée d'un 2ᵉ doigt (dépassement de max touches) :
                // en peinture, l'amorce de trait est jetée.
                if isRotating { onRotateEnded() } else { onPaintCancelled() }
            default:
                break
            }
        }

        @objc func handleTwoPan(_ recognizer: UIPanGestureRecognizer) {
            let size = self.size
            switch recognizer.state {
            case .began:
                onRotateBegan()
            case .changed:
                onRotateChanged(translation(recognizer), size)
            case .ended, .cancelled, .failed:
                onRotateEnded()
            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onZoomBegan()
            case .changed:
                onZoomChanged(recognizer.scale)
            case .ended, .cancelled, .failed:
                onZoomEnded()
            default:
                break
            }
        }

        /// Translation cumulée depuis le début du geste (équivalent à
        /// `DragGesture.Value.translation`).
        private func translation(_ recognizer: UIPanGestureRecognizer) -> CGSize {
            let t = recognizer.translation(in: view)
            return CGSize(width: t.x, height: t.y)
        }

        /// Reconnaissance simultanée **uniquement** du pan 2 doigts et du
        /// pincement (pan+zoom standard). Toute paire impliquant le pan 1 doigt
        /// reste exclusive — la peinture ne tourne jamais avec un geste caméra.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            MainActor.assumeIsolated {
                let pair: Set<ObjectIdentifier> = [
                    ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)
                ]
                guard let twoPan, let pinch else { return false }
                return pair == [ObjectIdentifier(twoPan), ObjectIdentifier(pinch)]
            }
        }
    }
}
