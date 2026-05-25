import simd

/// Couleur et intensité de l'éclairage selon la hauteur du soleil. Près de
/// l'horizon : chaud et faible (rougeoiement atmosphérique) ; haut dans le
/// ciel : blanc et intense. Type pur — l'exposition de la scène (point blanc de
/// la photo) est appliquée par-dessus par la Feature.
struct SkyLighting: Equatable {
    /// Couleur du soleil, intensité comprise dans la magnitude.
    var sunColor: SIMD3<Float>
    /// Lumière ambiante du ciel.
    var ambient: SIMD3<Float>

    init(sunAltitude altitude: Double) {
        let a = Float(altitude)
        // Facteur « jour » : 0 quand le soleil est sous l'horizon, 1 haut.
        let day = SkyLighting.smoothstep(-0.10, 0.30, a)
        // Teinte du soleil : chaude à l'horizon → blanche en hauteur.
        let hue = SkyLighting.smoothstep(0.0, 0.45, a)
        let warm = SIMD3<Float>(1.0, 0.50, 0.25)
        let white = SIMD3<Float>(1.0, 0.97, 0.90)

        let sunStrength = 1.5 + (9.0 - 1.5) * day
        sunColor = (warm + (white - warm) * hue) * sunStrength

        // Ambiance du ciel : le corps d'un nuage est surtout éclairé par la
        // voûte (diffusion multiple). En plein jour elle est claire et presque
        // blanche (les ombres d'un nuage sont gris clair, pas bleu sombre) ;
        // la nuit, sombre et froide. Porte l'essentiel de la « blancheur ».
        let ambientNight = SIMD3<Float>(0.05, 0.06, 0.10)
        let ambientDay = SIMD3<Float>(0.82, 0.86, 0.95)
        var sky = ambientNight + (ambientDay - ambientNight) * day

        // Lueur chaude du crépuscule/aube : pic quand le soleil frôle l'horizon,
        // nulle en plein jour comme en pleine nuit.
        let twilight = exp(-(a / 0.22) * (a / 0.22))
        sky += SIMD3<Float>(0.45, 0.26, 0.16) * twilight
        ambient = sky
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
