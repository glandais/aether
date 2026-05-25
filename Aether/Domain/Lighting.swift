import simd

/// Éclairage directionnel d'une scène (soleil ou lune dominant).
struct Lighting: Equatable, Sendable {
    /// Direction normalisée vers la source lumineuse, en espace monde.
    var direction: SIMD3<Float>
    var color: SIMD3<Float>
    var intensity: Float
    /// Lumière ambiante du ciel.
    var ambient: SIMD3<Float>
}
