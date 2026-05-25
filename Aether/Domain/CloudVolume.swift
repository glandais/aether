import simd

/// Description d'un volume de nuages dans l'espace monde. Type pur : les
/// densités réelles vivent dans les volume textures côté Rendering (étape 3).
struct CloudVolume: Equatable, Sendable {
    /// Demi-dimensions de la boîte englobante, en mètres.
    var halfExtent: SIMD3<Float>
    /// Altitude de la base du volume, en mètres.
    var baseAltitude: Float
    /// Facteur d'échelle global de densité (0 = transparent).
    var densityScale: Float
}
