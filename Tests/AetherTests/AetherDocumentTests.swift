import CoreGraphics
import Foundation
import Testing
import simd
@testable import Aether

/// Valide la persistance `.aether` : capturer l'état du canvas dans un
/// `AetherDocument`, le sérialiser puis le recharger doit reproduire à
/// l'identique les entrées du rendu (traits, paysage, scène, surcharges).
@MainActor
struct AetherDocumentTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    /// Petite image de fond (couleur unie) pour incarner le paysage embarqué.
    private func makeImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func roundTripReproducesState() throws {
        // État de canvas peint sur deux calques (cumulus + cirrus), avec des
        // surcharges météo distinctes par calque — pour vérifier qu'elles
        // survivent à l'aller-retour (et ne sont pas écrasées par les défauts).
        let model = CanvasModel()
        model.brushRadius = 0.1
        model.brushSoftness = 0.4
        let camera = StrokeCamera(
            right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, 1),
            tanHalfFov: 0.5, aspect: 1.5)
        model.selectGenus(.cumulus)
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: camera)
        model.extendStroke(to: SIMD2(0.62, 0.5))
        model.endStroke()
        model.selectGenus(.cirrus)
        model.beginStroke(at: SIMD2(0.3, 0.4), camera: camera)
        model.endStroke()
        model.setOpacity(0.7, for: .cirrus)
        model.setVisible(false, for: .cirrus)
        model.setRotation(yaw: 0.3, pitch: -0.2)
        #expect(model.layers.count == 2)

        let scene = Scene(
            title: "Test", coordinate: GeoCoordinate(latitude: 48.85, longitude: 2.35),
            date: utc(2026, 5, 25, 19, 15), timeZoneIdentifier: "Europe/Paris")
        let context = SceneContext(
            scene: scene, landscape: makeImage(width: 64, height: 40), displayAspect: 1.6,
            skyExposure: 0.7,
            cloudParameters: CloudParameters(coverageBias: 0.1, densityScale: 1.2),
            sea: .calm)

        // Capture → JSON → décodage → reconstruction.
        let document = try #require(AetherDocument(
            context: context, model: model,
            hourOverride: 14.5, dateOverride: utc(2026, 6, 1, 12, 0),
            coordinateOverride: GeoCoordinate(latitude: 10, longitude: 20),
            timeZoneOverride: TimeZone(identifier: "Asia/Tokyo"), fovOverride: 0.8))
        let data = try JSONEncoder().encode(document.payload)
        let reloaded = try AetherDocument.decode(from: data)
        let loaded = try #require(reloaded.makeLoaded())

        // Calques identiques (genre, traits, surcharges météo, visibilité) : les
        // surcharges par calque (opacité du cirrus, visibilité) sont préservées.
        #expect(loaded.restored.layers == model.layers)
        #expect(loaded.restored.viewYaw == 0.3)
        #expect(loaded.restored.viewPitch == -0.2)
        #expect(loaded.restored.brushRadius == 0.1)
        #expect(loaded.restored.brushSoftness == 0.4)

        // Surcharges d'instant / lieu / cadrage.
        #expect(loaded.restored.hourOverride == 14.5)
        #expect(loaded.restored.dateOverride == utc(2026, 6, 1, 12, 0))
        #expect(loaded.restored.coordinateOverride == GeoCoordinate(latitude: 10, longitude: 20))
        #expect(loaded.restored.timeZoneIdentifier == "Asia/Tokyo")
        #expect(loaded.restored.fovOverride == 0.8)

        // Scène et paramètres de rendu.
        #expect(loaded.context.scene == scene)
        #expect(loaded.context.skyExposure == 0.7)
        #expect(loaded.context.cloudParameters == CloudParameters(coverageBias: 0.1, densityScale: 1.2))
        #expect(loaded.context.sea == .calm)
        #expect(loaded.context.displayAspect == 1.6)

        // Paysage embarqué : mêmes dimensions après aller-retour PNG.
        #expect(loaded.context.landscape.width == 64)
        #expect(loaded.context.landscape.height == 40)
    }

    /// Recharger les calques dans un modèle neuf reproduit les calques à
    /// l'identique (mêmes traits cuits dans l'atlas de couverture, mêmes
    /// surcharges) : la réouverture rend à l'identique de l'enregistrement.
    @Test func loadRestoresLayersIdentically() throws {
        let model = CanvasModel()
        let camera = StrokeCamera(
            right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, 1),
            tanHalfFov: 0.5, aspect: 1.5)
        model.selectGenus(.cumulus)
        model.beginStroke(at: SIMD2(0.4, 0.5), camera: camera)
        model.extendStroke(to: SIMD2(0.55, 0.52))
        model.endStroke()
        model.selectGenus(.altocumulus)
        model.beginStroke(at: SIMD2(0.6, 0.35), camera: camera)
        model.endStroke()
        model.setOpacity(0.5, for: .altocumulus)
        let savedLayers = model.layers

        // Modèle neuf avec des défauts météo DIFFÉRENTS : ils ne doivent pas
        // surcharger les calques rechargés.
        let reopened = CanvasModel()
        reopened.applySceneDefaults(CloudParameters(coverageBias: 0.2, densityScale: 0.4))
        reopened.load(
            layers: savedLayers, viewYaw: 0.1, viewPitch: 0.0,
            brushRadius: 0.08, brushSoftness: 0.5)

        #expect(reopened.layers == savedLayers)
        // Tous les traits des calques rechargés reparaissent dans le modèle.
        #expect(reopened.strokes == savedLayers.flatMap(\.strokes))
    }

    /// Un fichier d'un schéma antérieur (v1, cubes) est refusé proprement avec
    /// l'erreur typée — pas de crash, pas de document à moitié chargé.
    @Test func rejectsLegacyVersionOneDocument() throws {
        let data = Data(#"{"version":1,"viewYaw":0,"cubes":[]}"#.utf8)
        #expect(throws: AetherDocumentError.unsupportedVersion(found: 1)) {
            _ = try AetherDocument.decode(from: data)
        }
    }

    /// Un fichier d'un schéma postérieur (futur v3) est lui aussi refusé en
    /// `unsupportedVersion` — pas signalé à tort comme corrompu.
    @Test func rejectsFutureVersionDocument() throws {
        let data = Data(#"{"version":3}"#.utf8)
        #expect(throws: AetherDocumentError.unsupportedVersion(found: 3)) {
            _ = try AetherDocument.decode(from: data)
        }
    }

    /// Un contenu non décodable (ni version lisible) est signalé `corrupted`,
    /// distinct de l'erreur de version.
    @Test func rejectsCorruptedContent() throws {
        let garbage = Data("not json".utf8)
        #expect(throws: AetherDocumentError.corrupted) {
            _ = try AetherDocument.decode(from: garbage)
        }
    }
}
