import Foundation

/// Fournit l'état météo à un point/instant. Source primaire WeatherKit
/// (entitlement requis), fallback Open-Meteo — voir `FallbackWeatherService`.
protocol WeatherService: Sendable {
    func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport
}
