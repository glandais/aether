import Foundation

/// Attribution de la source météo — affichée telle quelle (noms propres, pas de
/// localisation). Pur : pas de dépendance framework. Open-Meteo fournit des
/// constantes ; WeatherKit remplit les URLs depuis l'API Apple.
struct WeatherAttribution: Equatable, Sendable {
    var serviceName: String
    var legalURL: URL?
    var logoLightURL: URL?
    var logoDarkURL: URL?

    /// Attribution statique d'Open-Meteo (crédit CC-BY, pas de logo).
    static let openMeteo = WeatherAttribution(
        serviceName: "Open-Meteo",
        legalURL: URL(string: "https://open-meteo.com"),
        logoLightURL: nil,
        logoDarkURL: nil
    )
}
