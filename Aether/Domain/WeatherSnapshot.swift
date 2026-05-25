/// État météo à un point/instant — informe les paramètres initiaux des nuages.
struct WeatherSnapshot: Equatable, Sendable {
    enum Condition: String, Sendable {
        case clear
        case partlyCloudy
        case cloudy
        case overcast
        case fog
        case rain
        case snow
    }

    var condition: Condition
    /// Couverture nuageuse, 0…1.
    var cloudCover: Double
    /// Humidité relative, 0…1.
    var humidity: Double
    /// Vitesse du vent, en m/s.
    var windSpeed: Double
    /// Température, en °C.
    var temperature: Double
}
