import Testing
import simd
@testable import Aether

/// Valide l'éclairage selon la hauteur du soleil : plein jour = blanc et
/// lumineux, crépuscule = chaud et faible, nuit = quasi éteint.
struct SkyLightingTests {
    private func luminance(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    @Test("Le soleil haut est plus lumineux et plus blanc qu'au crépuscule")
    func highSunIsBrighterAndWhiter() {
        let noon = SkyLighting(sunAltitude: 1.2)    // ~69°
        let dusk = SkyLighting(sunAltitude: 0.05)   // ~3°

        #expect(luminance(noon.sunColor) > luminance(dusk.sunColor))
        // « Blancheur » : écart bleu/rouge plus faible en plein jour.
        let noonGap = noon.sunColor.x - noon.sunColor.z
        let duskGap = dusk.sunColor.x - dusk.sunColor.z
        #expect(noonGap < duskGap)
    }

    @Test("Sous l'horizon, l'éclairage est quasi éteint")
    func belowHorizonIsDim() {
        let night = SkyLighting(sunAltitude: -0.3)
        #expect(luminance(night.sunColor) < luminance(SkyLighting(sunAltitude: 0.2).sunColor))
        #expect(night.ambient.z < 0.2)
    }
}
