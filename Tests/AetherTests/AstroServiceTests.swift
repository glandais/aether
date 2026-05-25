import Foundation
import Testing
import simd
@testable import Aether

/// Valide le calcul astro (`SwiftAAAstroService`) et la conversion en direction
/// monde. Les assertions portent sur des invariants robustes (midi solaire au
/// Sud, lever à l'Est, Soleil sous l'horizon la nuit) plutôt que sur des valeurs
/// exactes, pour détecter sûrement les erreurs de convention.
struct AstroServiceTests {
    private let service = SwiftAAAstroService()

    /// Greenwich (lon 0), proche de l'équinoxe.
    private let greenwich = GeoCoordinate(latitude: 51.4779, longitude: 0.0)

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private func degrees(_ radians: Double) -> Double {
        radians * 180.0 / .pi
    }

    @Test("Au midi solaire, le Soleil est au Sud et haut dans le ciel")
    func sunAtSolarNoon() {
        let sun = service.position(of: .sun, at: greenwich, date: utc(2024, 3, 20, 12, 0))
        let azimuth = degrees(sun.azimuth)
        let altitude = degrees(sun.altitude)

        // Azimut ~180° (Sud) ; altitude ~ 90 - latitude ≈ 38,5°.
        #expect(azimuth > 165 && azimuth < 195)
        #expect(altitude > 32 && altitude < 45)
    }

    @Test("Au lever, le Soleil est à l'Est, proche de l'horizon")
    func sunAtSunrise() {
        let sun = service.position(of: .sun, at: greenwich, date: utc(2024, 3, 20, 6, 0))
        let azimuth = degrees(sun.azimuth)
        let altitude = degrees(sun.altitude)

        #expect(azimuth > 78 && azimuth < 102)
        #expect(altitude > -6 && altitude < 12)
    }

    @Test("À minuit, le Soleil est bien sous l'horizon")
    func sunBelowHorizonAtMidnight() {
        let sun = service.position(of: .sun, at: greenwich, date: utc(2024, 3, 20, 0, 0))
        #expect(degrees(sun.altitude) < -20)
    }

    @Test("La position de la Lune est dans des plages valides")
    func moonInValidRange() {
        let moon = service.position(of: .moon, at: greenwich, date: utc(2024, 3, 20, 22, 0))
        let azimuth = degrees(moon.azimuth)
        let altitude = degrees(moon.altitude)

        #expect(azimuth >= 0 && azimuth < 360)
        #expect(altitude >= -90 && altitude <= 90)
        #expect(moon.body == .moon)
    }

    @Test("La direction monde respecte la convention -Z = Nord, +X = Est")
    func worldDirectionConvention() {
        // Sud, 30° d'altitude → +Z (derrière, caméra face Nord), +Y vers le haut.
        let south = CelestialPosition(body: .sun, azimuth: .pi, altitude: .pi / 6)
        let southDir = south.worldDirection
        #expect(abs(southDir.x) < 1e-5)
        #expect(abs(southDir.y - 0.5) < 1e-5)
        #expect(southDir.z > 0.8)

        // Est, à l'horizon → +X.
        let east = CelestialPosition(body: .sun, azimuth: .pi / 2, altitude: 0)
        let eastDir = east.worldDirection
        #expect(abs(eastDir.x - 1.0) < 1e-5)
        #expect(abs(eastDir.y) < 1e-5)
        #expect(abs(eastDir.z) < 1e-5)
    }
}
