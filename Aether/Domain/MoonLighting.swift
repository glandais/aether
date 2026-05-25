import simd

/// Éclairage lunaire nocturne : froid et faible, modulé par la hauteur de la
/// lune et sa fraction éclairée (pleine lune claire, nouvelle lune sombre).
/// Type pur — l'exposition de la scène est appliquée par-dessus par la Feature.
struct MoonLighting: Equatable {
    /// Couleur de la lune, intensité comprise dans la magnitude (≪ soleil).
    var color: SIMD3<Float>
    /// Ambiance nocturne (sombre, légère teinte froide quand la lune éclaire).
    var ambient: SIMD3<Float>

    init(moonAltitude altitude: Double, illuminatedFraction: Double) {
        let a = Float(altitude)
        // 0 sous l'horizon → 1 haut.
        let up = SkyLighting.smoothstep(-0.10, 0.20, a)
        let phase = Float(max(0, min(1, illuminatedFraction)))
        // Lumière lunaire faible : magnitude bien inférieure au soleil (~9).
        let brightness = up * (0.15 + 0.85 * phase)

        let coolWhite = SIMD3<Float>(0.62, 0.72, 1.0)
        color = coolWhite * (2.2 * brightness)

        let nightFloor = SIMD3<Float>(0.03, 0.04, 0.07)
        ambient = nightFloor + SIMD3<Float>(0.10, 0.13, 0.22) * brightness
    }
}
