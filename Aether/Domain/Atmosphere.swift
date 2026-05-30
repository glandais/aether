import Foundation
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
/// fond en uniformes, exactement comme `CloudParameters`.
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

// MARK: - Intégrale de diffusion (port CPU de `Background.metal`)
//
// Sert à éclairer le nuage avec **la même** atmosphère que le ciel de fond :
// la couleur du soleil reçue par le nuage = transmittance solaire (chaude bas,
// blanche haut, nulle sous l'horizon) ; l'ambiance = radiance du ciel au zénith
// (bleue le jour). Quelques marches par frame (2 directions) → coût négligeable.
extension Atmosphere {
    private var eyeOrigin: SIMD3<Float> { SIMD3(0, planetRadius + eyeHeight, 0) }

    /// Transmittance RGB de la lumière solaire jusqu'au sol, le long du rayon
    /// vers le soleil. `nil`/0 si le soleil est sous l'horizon (rayon occlus).
    func sunTransmittance(sunDirection: SIMD3<Float>) -> SIMD3<Float> {
        guard let depth = opticalDepthToSpace(from: eyeOrigin, direction: simd_normalize(sunDirection)) else {
            return .zero
        }
        let tau = rayleighScattering * depth.rayleigh
            + SIMD3(repeating: mieScattering * 1.1 * depth.mie)
        return Atmosphere.expVector(-tau)
    }

    /// Radiance de diffusion simple (Rayleigh + Mie) le long d'un rayon de vue.
    /// Pour l'ambiance, l'appeler vers le zénith.
    func skyRadiance(viewDirection: SIMD3<Float>, sunDirection: SIMD3<Float>) -> SIMD3<Float> {
        let origin = eyeOrigin
        let rayDir = simd_normalize(viewDirection)
        let sunDir = simd_normalize(sunDirection)

        let atmosphere = Atmosphere.raySphere(origin, rayDir, atmosphereRadius)
        guard atmosphere.far >= 0 else { return .zero }
        var rayLength = atmosphere.far
        let ground = Atmosphere.raySphere(origin, rayDir, planetRadius)
        if ground.near > 0 { rayLength = min(rayLength, ground.near) }

        let primarySteps = 16
        let stepSize = rayLength / Float(primarySteps)
        let mu = simd_dot(rayDir, sunDir)
        let phaseR = (3.0 / (16.0 * Float.pi)) * (1 + mu * mu)
        let g = mieAnisotropy
        let gg = g * g
        let phaseM = (3.0 / (8.0 * Float.pi)) * ((1 - gg) * (1 + mu * mu))
            / ((2 + gg) * Float(pow(Double(1 + gg - 2 * g * mu), 1.5)))

        var rayleighSum = SIMD3<Float>.zero
        var mieSum = SIMD3<Float>.zero
        var opticalR: Float = 0
        var opticalM: Float = 0
        var t: Float = 0
        for _ in 0..<primarySteps {
            let pos = origin + rayDir * (t + 0.5 * stepSize)
            let height = simd_length(pos) - planetRadius
            let densityR = Float(Foundation.exp(Double(-height / rayleighScaleHeight))) * stepSize
            let densityM = Float(Foundation.exp(Double(-height / mieScaleHeight))) * stepSize
            opticalR += densityR
            opticalM += densityM
            t += stepSize
            guard let light = opticalDepthToSpace(from: pos, direction: sunDir) else { continue }
            let tau = rayleighScattering * (opticalR + light.rayleigh)
                + SIMD3(repeating: mieScattering * 1.1 * (opticalM + light.mie))
            let attenuation = Atmosphere.expVector(-tau)
            rayleighSum += densityR * attenuation
            mieSum += densityM * attenuation
        }
        return sunIntensity
            * (rayleighSum * rayleighScattering * phaseR
               + mieSum * SIMD3(repeating: mieScattering) * phaseM)
    }

    /// Profondeur optique (Rayleigh, Mie) du point vers le sommet de l'atmosphère.
    /// `nil` si le rayon retombe sous la surface (point dans l'ombre de la Terre).
    private func opticalDepthToSpace(
        from origin: SIMD3<Float>, direction: SIMD3<Float>
    ) -> (rayleigh: Float, mie: Float)? {
        let hit = Atmosphere.raySphere(origin, direction, atmosphereRadius)
        guard hit.far >= 0 else { return (0, 0) }
        let steps = 8
        let stepSize = hit.far / Float(steps)
        var rayleigh: Float = 0
        var mie: Float = 0
        var t = 0.5 * stepSize
        for _ in 0..<steps {
            let height = simd_length(origin + direction * t) - planetRadius
            if height < 0 { return nil }
            rayleigh += Float(Foundation.exp(Double(-height / rayleighScaleHeight))) * stepSize
            mie += Float(Foundation.exp(Double(-height / mieScaleHeight))) * stepSize
            t += stepSize
        }
        return (rayleigh, mie)
    }

    private static func raySphere(
        _ origin: SIMD3<Float>, _ direction: SIMD3<Float>, _ radius: Float
    ) -> (near: Float, far: Float) {
        let b = simd_dot(origin, direction)
        let c = simd_dot(origin, origin) - radius * radius
        let d = b * b - c
        if d < 0 { return (1, -1) }
        let root = d.squareRoot()
        return (-b - root, -b + root)
    }

    private static func expVector(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Float(Foundation.exp(Double(v.x))),
              Float(Foundation.exp(Double(v.y))),
              Float(Foundation.exp(Double(v.z))))
    }
}
