import simd

/// Un cube de densité de nuage, ancré sur une **direction de regard** figée à sa
/// création. Le canvas peut désormais peindre plusieurs masses nuageuses dans
/// des directions distinctes du ciel : chaque fois que le regard change et qu'un
/// nouveau trait commence, un nouveau cube naît, ancré sur le regard courant.
///
/// Les traits ne s'appliquent qu'au **cube courant** (le dernier créé) ; on ne
/// réutilise jamais un cube antérieur. Tous les traits d'un cube partagent donc
/// (à epsilon près) son `anchorForward`, ce qui garde le centre monde du cube et
/// la projection des traits alignés — le dépôt reste correct.
///
/// `anchorForward` = avant du regard (`CameraPose.basis.forward`, attitude scène
/// + rotation utilisateur) au moment de la création. Source unique du placement
/// monde du cube (le Rendering en dérive le centre : `anchorForward × distance`).
struct CloudCube: Equatable, Sendable {
    var anchorForward: SIMD3<Float>
    var strokes: [BrushStroke]

    /// Nombre maximal de cubes simultanés — **source unique** de la borne. La
    /// création (`CanvasModel`), l'atlas de densité et son slab par cube
    /// (`Renderer`) et le raymarch (passé en uniform à `Cloud.metal`) s'y réfèrent
    /// tous. Borne mémoire/perf : chaque cube ajoute un slab 96×96×48 (×2 en
    /// ping-pong) à l'atlas et un test boîte/rayon par pixel.
    static let maxCount = 12
}
