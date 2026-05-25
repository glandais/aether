/// Carte de profondeur dense, type pur de transport. Produite par un
/// `DepthService`, consommée par le Rendering pour l'occlusion des nuages par
/// le relief (étape 6). Vit dans le Domain car le Rendering ne dépend pas des
/// Services.
struct DepthMap: Equatable, Sendable {
    var width: Int
    var height: Int
    /// Profondeurs normalisées (0 = proche, 1 = lointain), ligne par ligne.
    var values: [Float]
}
