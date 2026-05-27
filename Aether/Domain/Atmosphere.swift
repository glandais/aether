import simd

/// Paramètres de diffusion atmosphérique (modèle physique simple, dans l'esprit
/// de CesiumJS `Atmosphere.js` / Hillaire 2020). Deux composantes :
///
/// - **Rayleigh** : diffusion par les molécules d'air. Le bleu diffuse ~6× plus
///   que le rouge → ciel bleu de jour, rougeoiement à l'horizon quand le soleil
///   est bas (le bleu est diffusé hors du trajet, il ne reste que le rouge).
/// - **Mie** : diffusion par les aérosols. Quasi achromatique, fort lobe avant
///   → halo blanchâtre serré autour du soleil.
///
/// Type pur Domain (ne dépend de rien). Le `Renderer` le transmet au shader de
/// fond en uniformes, exactement comme `Lighting` / `CloudParameters`.
/// Longueurs en mètres, coefficients de diffusion en m⁻¹.
struct Atmosphere: Equatable {
    /// Coefficient de diffusion de Rayleigh par composante (R, G, B), m⁻¹.
    var rayleighScattering: SIMD3<Float>
    /// Coefficient de diffusion de Mie (gris), m⁻¹.
    var mieScattering: Float
    /// Hauteur d'échelle de Rayleigh : altitude où la densité tombe à 1/e, m.
    var rayleighScaleHeight: Float
    /// Hauteur d'échelle de Mie, m.
    var mieScaleHeight: Float
    /// Anisotropie de Mie (g de Henyey-Greenstein) ∈ [0,1[ : 0 = isotrope,
    /// proche de 1 = lobe avant marqué (halo serré autour du soleil). Même
    /// fonction de phase que celle déjà utilisée pour le nuage (`Cloud.metal`).
    var mieAnisotropy: Float
    /// Rayon de la planète (surface), m.
    var planetRadius: Float
    /// Rayon du sommet de l'atmosphère, m.
    var atmosphereRadius: Float
    /// Hauteur de l'œil au-dessus de la surface, m (caméra au sol).
    var eyeHeight: Float
    /// Intensité de la lumière solaire incidente (échelle linéaire HDR).
    var sunIntensity: Float

    /// Valeurs terrestres canoniques (Bruneton / Hillaire 2020). Point de départ
    /// physiquement fondé ; à affiner artistiquement au besoin (registre sobre).
    static let earth = Atmosphere(
        rayleighScattering: SIMD3<Float>(5.802e-6, 13.558e-6, 33.1e-6),
        mieScattering: 3.996e-6,
        rayleighScaleHeight: 8000,
        mieScaleHeight: 1200,
        mieAnisotropy: 0.8,
        planetRadius: 6_360_000,
        atmosphereRadius: 6_460_000,
        eyeHeight: 1.7,
        sunIntensity: 20
    )
}
