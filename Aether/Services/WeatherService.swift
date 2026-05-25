import Foundation

/// Fournit l'état météo à un point/instant. Masque WeatherKit (fallback Open-Meteo).
protocol WeatherService: Sendable {
    func snapshot(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherSnapshot
}
