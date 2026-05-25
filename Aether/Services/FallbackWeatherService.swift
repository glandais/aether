import Foundation
import os

/// Compose plusieurs `WeatherService` en cascade : retourne le premier succès,
/// rejette la dernière erreur si tous échouent. Permet WeatherKit primaire +
/// Open-Meteo fallback derrière une seule façade.
struct FallbackWeatherService: WeatherService {
    enum CompositeError: Error { case noServices }

    private let services: [any WeatherService]
    private let log = Logger(subsystem: "io.github.glandais.aether", category: "weather")

    init(services: [any WeatherService]) {
        self.services = services
    }

    func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport {
        var lastError: (any Error)?
        for (index, service) in services.enumerated() {
            do {
                return try await service.report(at: coordinate, date: date)
            } catch {
                lastError = error
                log.notice("Source météo \(index, privacy: .public) indisponible, bascule sur la suivante.")
            }
        }
        throw lastError ?? CompositeError.noServices
    }
}
