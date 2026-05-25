import simd

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

extension CelestialPosition {
    /// Direction unitaire vers l'astre, en espace monde Aether. Ici `azimuth`
    /// est mesuré **depuis l'avant de la caméra** (et non depuis le Nord) :
    /// l'appelant y soustrait le cap de la scène. Convention monde : -Z = avant,
    /// +X = droite, +Y = haut. Type pur (pas de dépendance Services).
    var worldDirection: SIMD3<Float> {
        let azimuthRad = Float(azimuth)
        let altitudeRad = Float(altitude)
        let cosAltitude = cos(altitudeRad)
        let east = cosAltitude * sin(azimuthRad)
        let north = cosAltitude * cos(azimuthRad)
        let up = sin(altitudeRad)
        return SIMD3(east, up, -north)
    }
}
