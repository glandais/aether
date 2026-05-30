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
        // État de canvas peint (deux traits → un cube).
        let model = CanvasModel()
        model.brushRadius = 0.1
        model.brushSoftness = 0.4
        let camera = StrokeCamera(
            right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, 1),
            tanHalfFov: 0.5, aspect: 1.5)
        model.beginStroke(at: SIMD2(0.5, 0.5), camera: camera)
        model.extendStroke(to: SIMD2(0.62, 0.5))
        model.endStroke()
        model.setRotation(yaw: 0.3, pitch: -0.2)

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
        let payload = try JSONDecoder().decode(AetherDocument.Payload.self, from: data)
        let loaded = try #require(AetherDocument(payload: payload).makeLoaded())

        // Traits identiques (points + pose de caméra par trait).
        #expect(loaded.restored.cubes == model.cubes)
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
}
