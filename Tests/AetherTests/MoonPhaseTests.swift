import Testing
import simd
@testable import Aether

/// Valide la géométrie de la phase lunaire (port CPU reproduit par `moonDisc`
/// dans `Background.metal`).
struct MoonPhaseTests {
    @Test("Nouvelle lune : Soleil ≈ Lune → centre du disque dans l'ombre")
    func newMoonIsDark() {
        let moon = simd_normalize(SIMD3<Float>(1, 1, 0))
        let sun = moon  // Soleil derrière l'observateur, du même côté que la Lune
        #expect(MoonPhase.surfaceLit(a: 0, b: 0, moon: moon, sun: sun) < 0)
    }

    @Test("Pleine lune : Soleil ≈ −Lune → centre du disque éclairé")
    func fullMoonIsLit() {
        let moon = simd_normalize(SIMD3<Float>(1, 1, 0))
        let sun = -moon
        #expect(MoonPhase.surfaceLit(a: 0, b: 0, moon: moon, sun: sun) > 0)
    }

    @Test("Premier quartier : Soleil ⊥ Lune → limbe éclairé du côté du Soleil")
    func quarterBrightLimbFacesSun() {
        let moon = SIMD3<Float>(0, 0, -1)        // Lune au Nord
        let sun = SIMD3<Float>(1, 0, 0)          // Soleil à l'Est (perpendiculaire)
        // Le bord `a > 0` (vers le limbe éclairé) est plus clair que `a < 0`.
        let towardSun = MoonPhase.surfaceLit(a: 0.5, b: 0, moon: moon, sun: sun)
        let awayFromSun = MoonPhase.surfaceLit(a: -0.5, b: 0, moon: moon, sun: sun)
        #expect(towardSun > awayFromSun)
        #expect(towardSun > 0)        // côté Soleil éclairé
        #expect(awayFromSun < 0)      // côté opposé dans l'ombre
    }

    @Test("Direction du limbe : unitaire, orthogonale à la Lune, dans le demi-plan du Soleil")
    func brightLimbDirectionWellFormed() {
        let moon = simd_normalize(SIMD3<Float>(0.3, 0.8, -0.5))
        let sun = simd_normalize(SIMD3<Float>(-0.6, 0.2, 0.7))
        let limb = MoonPhase.brightLimbDirection(moon: moon, sun: sun)
        #expect(abs(simd_length(limb) - 1) < 1e-4)        // unitaire
        #expect(abs(simd_dot(limb, moon)) < 1e-4)         // orthogonale à la Lune
        #expect(simd_dot(limb, sun) > 0)                  // pointe vers le Soleil
    }

    @Test("Dégénéré (Soleil ∥ Lune) : vecteur fini, unitaire, orthogonal — pas de NaN")
    func brightLimbDirectionDegenerate() {
        let moon = simd_normalize(SIMD3<Float>(0, 1, 0))
        let limb = MoonPhase.brightLimbDirection(moon: moon, sun: moon)
        #expect(limb.x.isFinite && limb.y.isFinite && limb.z.isFinite)
        #expect(abs(simd_length(limb) - 1) < 1e-4)
        #expect(abs(simd_dot(limb, moon)) < 1e-4)
    }
}
