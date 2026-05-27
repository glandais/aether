import Foundation
import Testing
import simd
@testable import Aether

/// Valide la conversion équatorial → horizontal des étoiles (temps sidéral +
/// latitude) et le décodage binaire. Les assertions portent sur des invariants
/// géométriques robustes plutôt que sur des valeurs exactes.
struct StarCatalogTests {

    private func degrees(_ radians: Double) -> Double { radians * 180.0 / .pi }
    private func radians(_ degrees: Double) -> Double { degrees * .pi / 180.0 }

    @Test("L'étoile polaire (δ=90°) culmine au Nord, à une altitude = latitude")
    func celestialPoleAtLatitude() {
        let latitude = 48.0
        let pole = Star(rightAscension: 0, declination: .pi / 2, magnitude: 2, colorIndex: 0)
        // Au pôle céleste, l'heure sidérale n'a pas d'effet (δ=90°).
        let visible = StarCatalog.visibleStars([pole], latitude: latitude, siderealTime: 1.234)
        #expect(visible.count == 1)

        let direction = visible[0].direction
        // Altitude = latitude → composante verticale = sin(latitude).
        #expect(abs(Double(direction.y) - sin(radians(latitude))) < 1e-3)
        // Azimut Nord (-Z) : composante Est ~0, composante Nord (-z) positive.
        #expect(abs(direction.x) < 1e-3)
        #expect(direction.z < 0)  // -Z = Nord
    }

    @Test("Une étoile sur l'équateur au méridien culmine au Sud")
    func equatorOnMeridian() {
        let latitude = 45.0
        // Au méridien : angle horaire 0 → RA = temps sidéral.
        let sidereal = 1.0
        let star = Star(rightAscension: sidereal, declination: 0, magnitude: 2, colorIndex: 0)
        let visible = StarCatalog.visibleStars([star], latitude: latitude, siderealTime: sidereal)
        #expect(visible.count == 1)

        let direction = visible[0].direction
        // δ=0 < φ=45° → culmine au Sud (+Z), altitude = 90-φ = 45°.
        #expect(direction.z > 0)              // +Z = Sud
        #expect(abs(direction.x) < 1e-3)      // sur le méridien : pas de composante Est/Ouest
        #expect(abs(Double(direction.y) - sin(radians(45))) < 1e-3)
    }

    @Test("Une étoile sous l'horizon est écartée")
    func belowHorizonCulled() {
        let latitude = 45.0
        // Étoile au pôle Sud céleste (δ=-90°) : altitude = -latitude, sous l'horizon.
        let southPole = Star(rightAscension: 0, declination: -.pi / 2, magnitude: 1, colorIndex: 0)
        let visible = StarCatalog.visibleStars([southPole], latitude: latitude, siderealTime: 0)
        #expect(visible.isEmpty)
    }

    @Test("Le temps sidéral local est borné dans [0, 2π)")
    func siderealTimeBounded() {
        for hour in stride(from: 0.0, to: 48.0, by: 0.5) {
            let date = Date(timeIntervalSince1970: hour * 3600)
            let lst = StarCatalog.localSiderealTime(date: date, longitudeEast: 2.35)
            #expect(lst >= 0 && lst < 2 * .pi)
        }
    }

    @Test("Le temps sidéral avance d'environ 15°/heure")
    func siderealTimeRate() {
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = Date(timeIntervalSince1970: 3600)
        let lst0 = StarCatalog.localSiderealTime(date: t0, longitudeEast: 0)
        let lst1 = StarCatalog.localSiderealTime(date: t1, longitudeEast: 0)
        var delta = degrees(lst1 - lst0)
        if delta < 0 { delta += 360 }
        // ~15,041°/heure (jour sidéral ≈ 23h56m).
        #expect(delta > 15.0 && delta < 15.1)
    }

    @Test("Le décodage binaire reconstruit les enregistrements float32 LE")
    func decodeRoundTrip() {
        var data = Data()
        let values: [(Float, Float, Float, Float)] = [
            (0.0225, 0.7894, 6.70, 0.07),  // ~ HR 1
            (1.5, -0.3, 2.1, 1.2)
        ]
        for (ra, dec, vmag, bv) in values {
            for f in [ra, dec, vmag, bv] {
                var le = f.bitPattern.littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
        }
        let stars = StarCatalog.decode(data)
        #expect(stars.count == 2)
        #expect(abs(stars[0].rightAscension - 0.0225) < 1e-5)
        #expect(abs(stars[0].declination - 0.7894) < 1e-5)
        #expect(abs(stars[0].magnitude - 6.70) < 1e-4)
        #expect(abs(stars[1].colorIndex - 1.2) < 1e-4)
    }
}
