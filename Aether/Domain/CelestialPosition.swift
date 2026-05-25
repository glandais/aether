/// Position apparente d'un astre dans le ciel local (coordonnées horizontales).
struct CelestialPosition: Equatable, Sendable {
    enum Body: Sendable {
        case sun
        case moon
    }

    var body: Body
    /// Azimut en radians : 0 = Nord, sens horaire.
    var azimuth: Double
    /// Altitude au-dessus de l'horizon, en radians (négatif = sous l'horizon).
    var altitude: Double
}
