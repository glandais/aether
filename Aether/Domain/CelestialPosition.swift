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

    /// Direction vers l'astre dans le repère de la caméra de la scène, à partir
    /// de son attitude (yaw + pitch + roll). L'azimut est d'abord ramené
    /// relativement à l'avant de la caméra (− `heading`), puis la direction est
    /// tournée de −`roll` autour de l'axe avant (Z), enfin de −`pitch` autour de
    /// l'axe droit (X).
    func cameraDirection(heading: Double, pitch: Double, roll: Double = 0) -> SIMD3<Float> {
        let relative = CelestialPosition(body: body, azimuth: azimuth - heading, altitude: altitude)
        var direction = relative.worldDirection

        // Roulis : rotation de −roll autour de l'axe avant Z.
        let cosR = Float(cos(-roll))
        let sinR = Float(sin(-roll))
        direction = SIMD3(
            direction.x * cosR - direction.y * sinR,
            direction.x * sinR + direction.y * cosR,
            direction.z
        )

        // Tangage : rotation de −pitch autour de l'axe droit X.
        let cosP = Float(cos(-pitch))
        let sinP = Float(sin(-pitch))
        direction = SIMD3(
            direction.x,
            direction.y * cosP - direction.z * sinP,
            direction.y * sinP + direction.z * cosP
        )
        return direction
    }
}
