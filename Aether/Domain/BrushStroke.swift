import simd

/// Un trait de pinceau dans le canvas 2D normalisé ([0,1]²).
/// Converti en champ de densité par le Rendering (étape 4).
struct BrushStroke: Equatable, Sendable {
    var points: [SIMD2<Float>]
    /// Rayon du pinceau, en coordonnées normalisées.
    var radius: Float
    /// Adoucissement des bords (0 = net, 1 = très diffus).
    var softness: Float
}
