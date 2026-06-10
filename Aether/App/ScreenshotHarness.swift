#if DEBUG
import CoreGraphics
import Foundation
import simd

/// **Harnais de capture d'écran — DEBUG/temporaire.**
///
/// Pilote l'app par variable d'environnement `AETHER_SHOT` pour produire des
/// captures App Store déterministes : ouvre un paysage curé donné, injecte un
/// nuage pré-peint, force l'heure, et masque éventuellement l'interface. Le
/// rendu Metal n'étant pas testable, c'est la voie recommandée par CLAUDE.md
/// (« injecter un trait pré-peint, capturer, puis retirer le code temporaire »).
///
/// Format : `AETHER_SHOT=scene:hour:chrome:cloud`
///   - scene  : `dusk` | `dawn` | `blue` | `noon`   (index galerie 0…3)
///   - hour   : heure locale décimale, ex. `12` `17.5` `22`  (`-` = défaut scène)
///   - chrome : `hidden` | `shown`
///   - cloud  : `cumulus` | `scattered` | `band` | `none`
///
/// Si la variable est absente ou vaut `gallery`, le harnais est inactif (l'app
/// démarre sur la galerie normale).
enum ScreenshotHarness {
    struct Setup {
        var context: SceneContext
        var restored: RestoredCanvasState
        var chromeHidden: Bool
    }

    /// Lit `AETHER_SHOT` et construit la scène + l'état de canvas injecté. `nil`
    /// si le harnais est inactif (démarrage galerie normal).
    static func setupFromEnvironment() -> Setup? {
        guard let raw = ProcessInfo.processInfo.environment["AETHER_SHOT"],
              !raw.isEmpty, raw != "gallery" else {
            return nil
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let sceneKey = parts.indices.contains(0) ? parts[0] : "noon"
        let hourStr = parts.indices.contains(1) ? parts[1] : "-"
        let chromeStr = parts.indices.contains(2) ? parts[2] : "hidden"
        let cloudStr = parts.indices.contains(3) ? parts[3] : "cumulus"

        let index: Int
        switch sceneKey {
        case "dusk": index = 0
        case "dawn": index = 1
        case "blue": index = 2
        default: index = 3  // noon
        }
        let catalog = CuratedLandscape.catalog
        guard catalog.indices.contains(index),
              let context = catalog[index].makeContext() else {
            return nil
        }

        let hourOverride = Double(hourStr)
        let chromeHidden = chromeStr != "shown"

        let pose = CameraPose(heading: context.scene.heading, pitch: context.scene.pitch)
        let basis = pose.basis
        let camera = StrokeCamera(
            right: basis.right, up: basis.up, forward: basis.forward,
            tanHalfFov: Float(tan(context.scene.fieldOfView / 2)),
            aspect: 1320.0 / 2868.0)

        // Applique les défauts météo de la scène (`CloudParameters`) aux calques
        // injectés, **exactement** comme `CanvasModel.applySceneDefaults` le fait
        // pour un calque peint à la main : sans ça les nuages debug seraient plus
        // pleins/opaques (coverageBias 0, opacity 1) que ceux qu'on peint vraiment.
        let params = context.cloudParameters
        let layers = makeLayers(style: cloudStr, camera: camera).map { layer in
            CloudLayer(
                genus: layer.genus, strokes: layer.strokes,
                coverageBias: params.coverageBias,
                opacity: min(max(params.densityScale, 0), 1),
                isVisible: layer.isVisible)
        }

        let restored = RestoredCanvasState(
            layers: layers, viewYaw: 0, viewPitch: 0,
            brushRadius: 0.09, brushSoftness: 0.6,
            hourOverride: hourOverride, dateOverride: nil,
            coordinateOverride: nil, timeZoneIdentifier: nil, fovOverride: nil)

        return Setup(context: context, restored: restored, chromeHidden: chromeHidden)
    }

    // MARK: - Construction de nuages pré-peints

    private static func makeLayers(style: String, camera: StrokeCamera) -> [CloudLayer] {
        let strokes: [BrushStroke]
        switch style {
        case "none":
            return []
        case "scattered":
            strokes =
                cumulus(centerX: 0.30, centerY: 0.36, scale: 0.6, camera: camera)
                + cumulus(centerX: 0.66, centerY: 0.30, scale: 0.45, camera: camera)
                + cumulus(centerX: 0.50, centerY: 0.46, scale: 0.5, camera: camera)
        case "band":
            strokes = band(centerY: 0.40, camera: camera)
        default:  // cumulus
            strokes = cumulus(centerX: 0.50, centerY: 0.40, scale: 1.0, camera: camera)
        }
        return [CloudLayer(genus: .cumulus, strokes: strokes)]
    }

    /// Un cumulus en tas : rangées horizontales superposées, plus larges en bas,
    /// se resserrant vers le sommet — silhouette de nuage bombé.
    private static func cumulus(
        centerX: Float, centerY: Float, scale: Float, camera: StrokeCamera
    ) -> [BrushStroke] {
        // (décalage vertical depuis le centre, demi-largeur) — base → couronne.
        let rows: [(dy: Float, halfWidth: Float)] = [
            (0.060, 0.130),
            (0.020, 0.135),
            (-0.025, 0.110),
            (-0.070, 0.075),
            (-0.110, 0.035)
        ]
        let radius: Float = 0.085 * scale + 0.02
        return rows.map { row in
            let y = centerY + row.dy * scale
            let half = row.halfWidth * scale
            let points = stride(from: -half, through: half, by: max(0.02, half / 3))
                .map { SIMD2<Float>(centerX + $0, y) }
            return BrushStroke(
                points: points.isEmpty ? [SIMD2(centerX, y)] : points,
                radius: radius, softness: 0.6, camera: camera)
        }
    }

    /// Une bande nuageuse basse et large (ciel couvert / heure bleue).
    private static func band(centerY: Float, camera: StrokeCamera) -> [BrushStroke] {
        let rows: [(dy: Float, half: Float)] = [
            (0.03, 0.42), (0.0, 0.45), (-0.04, 0.40), (-0.08, 0.30)
        ]
        return rows.map { row in
            let y = centerY + row.dy
            let points = stride(from: -row.half, through: row.half, by: 0.06)
                .map { SIMD2<Float>(0.5 + $0, y) }
            return BrushStroke(points: points, radius: 0.11, softness: 0.7, camera: camera)
        }
    }
}
#endif
