/// Résultat d'une requête météo : l'instantané et l'attribution de la source
/// qui a effectivement répondu.
struct WeatherReport: Equatable, Sendable {
    var snapshot: WeatherSnapshot
    var attribution: WeatherAttribution
}
