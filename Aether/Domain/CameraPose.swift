import simd

/// Orientation de la caméra (lacet + tangage) dans le repère monde Aether.
/// Convention partagée avec `CelestialPosition` : -Z = avant (Nord à lacet 0),
/// +X = droite (Est), +Y = haut. `heading` est mesuré comme l'azimut (0 = Nord,
/// sens horaire) ; `pitch` > 0 vise vers le haut. Type pur (couche Domain).
///
/// `cameraDirection(heading:pitch:roll:)` transforme une direction **monde →
/// caméra** via `M_pitch · M_yaw`. La base ci-dessous est la caméra → monde
/// (transposée), de sorte que le rayon de vue du ciel et l'éclairage du nuage
/// restent cohérents (cf. `CameraPoseTests`). Le roulis est supposé nul.
struct CameraPose: Equatable, Sendable {
    var heading: Double
    var pitch: Double

    /// Vecteurs de base de la caméra exprimés en monde. `forward` est la
    /// direction de visée (image monde de l'axe caméra -Z). Orthonormés.
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let h = heading
        let p = pitch
        let cosH = Float(cos(h))
        let sinH = Float(sin(h))
        let cosP = Float(cos(p))
        let sinP = Float(sin(p))

        let right = SIMD3<Float>(cosH, 0, sinH)
        let up = SIMD3<Float>(-sinH * sinP, cosP, cosH * sinP)
        let forward = SIMD3<Float>(sinH * cosP, sinP, -cosH * cosP)
        return (right, up, forward)
    }
}
