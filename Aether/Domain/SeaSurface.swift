import simd

/// Surface de mer rendue sous l'horizon (raymarching de hauteur, technique
/// « Seascape » d'Alexander Alekseev / TDM portée en MSL). Quand un paysage
/// curé l'active, la branche sous-horizon de `Background.metal` remplace le ton
/// de sol par une mer ondulée : Fresnel + reflet du ciel (même atmosphère que le
/// fond) + miroitement du soleil.
///
/// Type pur Domain (ne dépend de rien). Le `Renderer` le transmet au shader de
/// fond en uniformes, exactement comme `Atmosphere` / `CloudParameters`.
/// Longueurs en mètres ; couleurs en linéaire.
///
/// Registre éditorial **contemplatif** : `.calm` privilégie une houle lente et
/// peu hachée (`choppy`/`speed` atténués par rapport au shader d'origine).
struct SeaSurface: Equatable, Sendable {
    /// La mer est-elle rendue pour ce paysage ?
    var enabled: Bool
    /// Hauteur de l'œil au-dessus du plan de mer, m → plan en `y = -level`.
    var level: Float
    /// Amplitude des vagues (SEA_HEIGHT d'origine).
    var height: Float
    /// Hachure des crêtes (SEA_CHOPPY) : bas = mer calme.
    var choppy: Float
    /// Fréquence spatiale de la houle (SEA_FREQ).
    var frequency: Float
    /// Vitesse d'animation (SEA_SPEED) : lent = contemplatif.
    var speed: Float
    /// Couleur de base de l'eau profonde (SEA_BASE), linéaire.
    var baseColor: SIMD3<Float>
    /// Teinte diffuse de l'eau (SEA_WATER_COLOR), linéaire.
    var waterColor: SIMD3<Float>

    /// Pas de mer (paysage terrestre) : la branche sous-horizon garde le sol.
    static let none = SeaSurface(
        enabled: false,
        level: 3.0,
        height: 0.6,
        choppy: 4.0,
        frequency: 0.16,
        speed: 0.8,
        baseColor: SIMD3<Float>(0.0, 0.09, 0.18),
        waterColor: SIMD3<Float>(0.48, 0.54, 0.36)
    )

    /// Mer calme par défaut (registre contemplatif) : houle lente, peu hachée.
    /// Valeurs « Seascape » de TDM, `choppy`/`speed` adoucis.
    static let calm = SeaSurface(
        enabled: true,
        level: 3.0,
        height: 0.6,
        choppy: 2.5,
        frequency: 0.16,
        speed: 0.5,
        baseColor: SIMD3<Float>(0.0, 0.09, 0.18),
        waterColor: SIMD3<Float>(0.48, 0.54, 0.36)
    )
}
