import Testing
import Foundation
@testable import Aether

/// Valide la logique de bascule du composite, hors ligne (stubs en mémoire).
struct FallbackWeatherServiceTests {
    /// Stub renvoyant un résultat fixe sans toucher au réseau.
    private struct StubWeatherService: WeatherService {
        let result: Result<WeatherReport, any Error>
        func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport {
            try result.get()
        }
    }

    private enum StubError: Error { case unavailable }

    private static let coordinate = GeoCoordinate(latitude: 48.85, longitude: 2.35)

    private static func report(named name: String) -> WeatherReport {
        WeatherReport(
            snapshot: WeatherSnapshot(
                condition: .cloudy, cloudCover: 0.5, humidity: 0.6,
                windSpeed: 3, temperature: 14),
            attribution: WeatherAttribution(serviceName: name, legalURL: nil,
                                            logoLightURL: nil, logoDarkURL: nil))
    }

    @Test("Le service primaire qui réussit est utilisé tel quel")
    func primarySucceeds() async throws {
        let primary = StubWeatherService(result: .success(Self.report(named: "Primary")))
        let secondary = StubWeatherService(result: .success(Self.report(named: "Secondary")))
        let service = FallbackWeatherService(services: [primary, secondary])

        let report = try await service.report(at: Self.coordinate, date: Date())
        #expect(report.attribution.serviceName == "Primary")
    }

    @Test("Si le primaire échoue, le secondaire sert (attribution de la source réelle)")
    func fallsBackToSecondary() async throws {
        let primary = StubWeatherService(result: .failure(StubError.unavailable))
        let secondary = StubWeatherService(result: .success(Self.report(named: "Secondary")))
        let service = FallbackWeatherService(services: [primary, secondary])

        let report = try await service.report(at: Self.coordinate, date: Date())
        #expect(report.attribution.serviceName == "Secondary")
    }

    @Test("Si tous échouent, la dernière erreur est propagée")
    func allFailRethrows() async {
        let primary = StubWeatherService(result: .failure(StubError.unavailable))
        let secondary = StubWeatherService(result: .failure(StubError.unavailable))
        let service = FallbackWeatherService(services: [primary, secondary])

        await #expect(throws: StubError.self) {
            _ = try await service.report(at: Self.coordinate, date: Date())
        }
    }
}
