import Foundation
import CoreLocation
import WeatherKit

/// Source météo primaire via WeatherKit (entitlement `com.apple.developer.weatherkit`
/// requis). Toute erreur ou absence de donnée pour la date → `throw`, pour que
/// `FallbackWeatherService` bascule sur Open-Meteo. `WeatherKit.WeatherService`
/// est qualifié pour éviter la collision avec notre protocole `WeatherService`.
struct WeatherKitWeatherService: WeatherService {
    enum ServiceError: Error { case noDataForDate }

    func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let service = WeatherKit.WeatherService.shared

        // Fenêtre d'une heure autour de l'instant demandé.
        let hourStart = Calendar(identifier: .gregorian).date(
            bySetting: .minute, value: 0, of: date) ?? date
        let forecast = try await service.weather(
            for: location,
            including: .hourly(startDate: hourStart, endDate: hourStart.addingTimeInterval(3600)))

        guard let hour = forecast.first else {
            throw ServiceError.noDataForDate
        }

        let snapshot = WeatherSnapshot(
            condition: WeatherSnapshot.Condition(weatherKit: hour.condition),
            cloudCover: hour.cloudCover,
            humidity: hour.humidity,
            windSpeed: hour.wind.speed.converted(to: .metersPerSecond).value,
            temperature: hour.temperature.converted(to: .celsius).value)

        let attribution = try await Self.attribution()
        return WeatherReport(snapshot: snapshot, attribution: attribution)
    }

    private static func attribution() async throws -> WeatherAttribution {
        let credit = try await WeatherKit.WeatherService.shared.attribution
        return WeatherAttribution(
            serviceName: "\u{f8ff} Weather",   //  Weather
            legalURL: credit.legalPageURL,
            logoLightURL: credit.combinedMarkLightURL,
            logoDarkURL: credit.combinedMarkDarkURL)
    }
}

extension WeatherSnapshot.Condition {
    /// Mappe une `WeatherKit.WeatherCondition` vers le Domain. Les cas non
    /// énumérés retombent sur `.cloudy` (couverture moyenne plausible).
    init(weatherKit condition: WeatherCondition) {
        switch condition {
        case .clear, .mostlyClear, .hot:
            self = .clear
        case .partlyCloudy:
            self = .partlyCloudy
        case .cloudy, .mostlyCloudy:
            self = .cloudy
        case .foggy, .haze, .smoky:
            self = .fog
        case .drizzle, .rain, .heavyRain, .thunderstorms, .sleet, .hail:
            self = .rain
        case .snow, .heavySnow, .flurries, .blizzard:
            self = .snow
        default:
            self = .cloudy
        }
    }
}
