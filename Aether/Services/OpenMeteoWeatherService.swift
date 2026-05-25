import Foundation

/// Implémentation d'`WeatherService` via l'API publique Open-Meteo (sans clé).
/// C'est le fallback documenté de WeatherKit, lequel nécessite un entitlement
/// (à brancher plus tard derrière le même protocole).
struct OpenMeteoWeatherService: WeatherService {
    enum ServiceError: Error {
        case invalidResponse
        case noDataForDate
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func snapshot(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let day = Self.dayFormatter.string(from: date)
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "cloud_cover,relative_humidity_2m,temperature_2m,wind_speed_10m"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "start_date", value: day),
            URLQueryItem(name: "end_date", value: day)
        ]
        guard let url = components.url else {
            throw ServiceError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.invalidResponse
        }

        let payload = try JSONDecoder().decode(Response.self, from: data)
        return try payload.snapshot(forHourMatching: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:00"
        return formatter
    }()

    // MARK: - Décodage

    private struct Response: Decodable {
        let hourly: Hourly

        struct Hourly: Decodable {
            let time: [String]
            let cloudCover: [Double]
            let relativeHumidity: [Double]
            let temperature: [Double]
            let windSpeed: [Double]

            enum CodingKeys: String, CodingKey {
                case time
                case cloudCover = "cloud_cover"
                case relativeHumidity = "relative_humidity_2m"
                case temperature = "temperature_2m"
                case windSpeed = "wind_speed_10m"
            }
        }

        func snapshot(forHourMatching date: Date) throws -> WeatherSnapshot {
            let key = OpenMeteoWeatherService.hourFormatter.string(from: date)
            let index = hourly.time.firstIndex(of: key) ?? 0
            guard hourly.cloudCover.indices.contains(index) else {
                throw ServiceError.noDataForDate
            }
            let cover = hourly.cloudCover[index] / 100.0
            return WeatherSnapshot(
                condition: WeatherSnapshot.condition(forCloudCover: cover),
                cloudCover: cover,
                humidity: hourly.relativeHumidity[index] / 100.0,
                windSpeed: hourly.windSpeed[index],
                temperature: hourly.temperature[index]
            )
        }
    }
}

private extension WeatherSnapshot {
    static func condition(forCloudCover cover: Double) -> Condition {
        switch cover {
        case ..<0.1: return .clear
        case ..<0.4: return .partlyCloudy
        case ..<0.75: return .cloudy
        default: return .overcast
        }
    }
}
