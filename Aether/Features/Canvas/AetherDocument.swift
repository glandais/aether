import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Type de document exporté pour les fichiers `.aether` (un ciel peint, complet
/// et autonome). Déclaré dans `Info.plist` (`UTExportedTypeDeclarations`).
extension UTType {
    static let aetherScene = UTType(exportedAs: "io.github.glandais.aether.scene")
}

/// État du canvas restauré depuis un fichier `.aether`, prêt à réamorcer une
/// `CanvasView` (traits, regard, pinceau et surcharges d'instant/lieu/FOV).
struct RestoredCanvasState {
    var cubes: [CloudCube]
    var viewYaw: Float
    var viewPitch: Float
    var brushRadius: Float
    var brushSoftness: Float
    var hourOverride: Double?
    var dateOverride: Date?
    var coordinateOverride: GeoCoordinate?
    var timeZoneIdentifier: String?
    var fovOverride: Double?

    /// Fuseau reconstruit depuis l'identifiant IANA stocké (s'il est connu).
    var timeZoneOverride: TimeZone? {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }
}

/// Une scène rechargée : le contexte de rendu reconstruit (scène + paysage
/// décodé) et l'état du canvas à réappliquer.
struct LoadedScene {
    var context: SceneContext
    var restored: RestoredCanvasState
}

/// Document `.aether` : persiste **tout** ce dont dépend l'image rendue, pour la
/// reproduire à l'identique au rechargement. La lumière, les astres et les
/// étoiles sont recalculés depuis le lieu + l'instant : on ne stocke que les
/// entrées, jamais le dérivé. Le paysage (procédural, sans référence stable) est
/// embarqué en PNG → fichier autonome.
struct AetherDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.aetherScene]
    static let writableContentTypes: [UTType] = [.aetherScene]

    /// Contenu sérialisé (JSON). `version` ouvre une migration ultérieure.
    struct Payload: Codable {
        var version: Int = 1
        var scene: Scene
        /// Aspect d'affichage (lettrage) ; `nil` = plein cadre.
        var displayAspect: Double?
        var skyExposure: Float
        var cloudParameters: CloudParameters
        var sea: SeaSurface
        /// Paysage de fond embarqué (PNG).
        var landscapePNG: Data
        var cubes: [CloudCube]
        var viewYaw: Float
        var viewPitch: Float
        var brushRadius: Float
        var brushSoftness: Float
        var hourOverride: Double?
        var dateOverride: Date?
        var coordinateOverride: GeoCoordinate?
        var timeZoneIdentifier: String?
        var fovOverride: Double?
    }

    var payload: Payload

    init(payload: Payload) {
        self.payload = payload
    }

    /// Capture l'état courant du canvas. Lit le `CanvasModel` (isolé main).
    @MainActor
    init?(
        context: SceneContext,
        model: CanvasModel,
        hourOverride: Double?,
        dateOverride: Date?,
        coordinateOverride: GeoCoordinate?,
        timeZoneOverride: TimeZone?,
        fovOverride: Double?
    ) {
        guard let png = context.landscape.pngData() else { return nil }
        payload = Payload(
            scene: context.scene,
            displayAspect: context.displayAspect.map { Double($0) },
            skyExposure: context.skyExposure,
            cloudParameters: context.cloudParameters,
            sea: context.sea,
            landscapePNG: png,
            cubes: model.cubes,
            viewYaw: model.viewYaw,
            viewPitch: model.viewPitch,
            brushRadius: model.brushRadius,
            brushSoftness: model.brushSoftness,
            hourOverride: hourOverride,
            dateOverride: dateOverride,
            coordinateOverride: coordinateOverride,
            timeZoneIdentifier: timeZoneOverride?.identifier,
            fovOverride: fovOverride)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        payload = try JSONDecoder().decode(Payload.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(payload)
        return FileWrapper(regularFileWithContents: data)
    }

    /// Reconstruit le contexte de rendu et l'état de canvas. `nil` si le paysage
    /// embarqué est illisible.
    func makeLoaded() -> LoadedScene? {
        guard let image = CGImage.from(pngData: payload.landscapePNG) else { return nil }
        let context = SceneContext(
            scene: payload.scene,
            landscape: image,
            displayAspect: payload.displayAspect.map { CGFloat($0) },
            skyExposure: payload.skyExposure,
            cloudParameters: payload.cloudParameters,
            sea: payload.sea)
        let restored = RestoredCanvasState(
            cubes: payload.cubes,
            viewYaw: payload.viewYaw,
            viewPitch: payload.viewPitch,
            brushRadius: payload.brushRadius,
            brushSoftness: payload.brushSoftness,
            hourOverride: payload.hourOverride,
            dateOverride: payload.dateOverride,
            coordinateOverride: payload.coordinateOverride,
            timeZoneIdentifier: payload.timeZoneIdentifier,
            fovOverride: payload.fovOverride)
        return LoadedScene(context: context, restored: restored)
    }
}
