import Foundation
import Testing
@testable import Aether

/// Valide la résolution de fuseau par coordonnée (`TzfTimeZoneService`, basé sur
/// tzf). Vérifie l'intégration du package et la convention de longitude (Est
/// positif, pas d'inversion).
struct TimeZoneServiceTests {
    private let service = TzfTimeZoneService()

    @Test func resolvesParis() async {
        let zone = await service.timeZone(
            for: GeoCoordinate(latitude: 48.8566, longitude: 2.3522))
        #expect(zone?.identifier == "Europe/Paris")
    }

    @Test func resolvesSydney() async {
        let zone = await service.timeZone(
            for: GeoCoordinate(latitude: -33.8688, longitude: 151.2093))
        #expect(zone?.identifier == "Australia/Sydney")
    }

    /// Convention de longitude : New York (lon négative, Ouest) ne doit pas être
    /// confondu avec un fuseau asiatique (inversion de signe).
    @Test func resolvesNewYork() async {
        let zone = await service.timeZone(
            for: GeoCoordinate(latitude: 40.7128, longitude: -74.0060))
        #expect(zone?.identifier == "America/New_York")
    }
}
