import Foundation
import Testing
@testable import Aether

/// Valide l'éphéméride (`SwiftAAAstroService.ephemeris`) : ordre lever/coucher
/// aux latitudes tempérées, et surtout le **cas circumpolaire** des hautes
/// latitudes (soleil de minuit / nuit polaire), qui ne doit pas dégénérer en
/// lever/coucher absents mais en `alwaysUp` / `alwaysDown`.
struct EphemerisTests {
    private let service = SwiftAAAstroService()

    private let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
    /// Cap Nord (Norvège), bien au-delà du cercle arctique (66,56°N).
    private let northCape = GeoCoordinate(latitude: 71.1700, longitude: 25.7800)

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test("À Paris en mai, le Soleil se lève avant de se coucher")
    func parisSunRisesBeforeSetting() {
        let ephemeris = service.ephemeris(at: paris, date: utc(2026, 5, 25))
        guard case let .rises(rise, set) = ephemeris.sun, let rise, let set else {
            Issue.record("Le Soleil devrait se lever et se coucher à Paris en mai")
            return
        }
        #expect(rise < set)
    }

    @Test("Au Cap Nord au solstice d'été, le Soleil ne se couche pas (soleil de minuit)")
    func northCapeMidnightSun() {
        let ephemeris = service.ephemeris(at: northCape, date: utc(2026, 6, 21))
        #expect(ephemeris.sun == .alwaysUp)
    }

    @Test("Au Cap Nord au solstice d'hiver, le Soleil ne se lève pas (nuit polaire)")
    func northCapePolarNight() {
        let ephemeris = service.ephemeris(at: northCape, date: utc(2026, 12, 21))
        #expect(ephemeris.sun == .alwaysDown)
    }

    @Test("La fraction éclairée de la Lune reste dans [0, 1]")
    func moonIlluminationBounded() {
        let ephemeris = service.ephemeris(at: paris, date: utc(2026, 5, 25))
        #expect(ephemeris.moonIllumination >= 0 && ephemeris.moonIllumination <= 1)
    }
}
