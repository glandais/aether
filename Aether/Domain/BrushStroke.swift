import simd

/// Base caméra → monde du regard au **moment** où un trait est peint, plus le
/// zoom et l'aspect du canvas. Le volume de nuage étant à position réelle en
/// monde, le Rendering projette chaque trait dans le volume via cette pose : un
/// trait peint sous un angle donné s'y dépose correctement, et reste en place
/// quand on tourne ensuite le regard. Convention partagée avec `CameraPose`.
struct StrokeCamera: Equatable, Sendable, Codable {
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var forward: SIMD3<Float>
    /// tan(FOV vertical / 2) au moment du trait.
    var tanHalfFov: Float
    /// Aspect du canvas peint (largeur/hauteur de la zone de geste, pas du
    /// drawable) : c'est la normalisation contre laquelle `points` est exprimé.
    var aspect: Float
}

/// Un trait de pinceau dans le canvas 2D normalisé ([0,1]²).
/// Converti en champ de densité par le Rendering (étape 4).
struct BrushStroke: Equatable, Sendable, Codable {
    var points: [SIMD2<Float>]
    /// Rayon du pinceau, en coordonnées normalisées.
    var radius: Float
    /// Adoucissement des bords (0 = net, 1 = très diffus).
    var softness: Float
    /// Pose de la caméra au moment où le trait a été peint (projection en monde).
    var camera: StrokeCamera
}
