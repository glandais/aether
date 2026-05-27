import Testing
import simd
@testable import Aether

/// Valide l'intégrale de diffusion atmosphérique (port CPU) qui éclaire le nuage.
struct AtmosphereTests {
    private let atmosphere = Atmosphere.earth

    private func luminance(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    @Test("Transmittance solaire : claire et tiède au zénith, chaude et sombre bas, nulle sous l'horizon")
    func sunTransmittance() {
        let high = atmosphere.sunTransmittance(sunDirection: SIMD3(0, 1, 0))
        // Au zénith : peu atténuée, et déjà plus chaude (rouge moins diffusé que bleu).
        #expect(high.x > 0.8)
        #expect(high.x > high.z)

        let low = atmosphere.sunTransmittance(sunDirection: simd_normalize(SIMD3(1, 0.06, 0)))
        #expect(luminance(low) < luminance(high))  // soleil rasant → plus sombre
        #expect(low.x > low.z)                       // et plus chaud encore

        let below = atmosphere.sunTransmittance(sunDirection: SIMD3(0, -0.5, -0.5))
        #expect(below == .zero)                      // sous l'horizon → occlus
    }

    @Test("Radiance du ciel : plus claire et bleutée le jour qu'à la nuit")
    func skyRadiance() {
        let day = atmosphere.skyRadiance(viewDirection: SIMD3(0, 1, 0), sunDirection: SIMD3(0, 1, 0))
        let night = atmosphere.skyRadiance(viewDirection: SIMD3(0, 1, 0), sunDirection: SIMD3(0, -1, 0))

        #expect(luminance(day) > luminance(night))
        #expect(day.z >= day.x)  // zénith bleuté (Rayleigh diffuse plus le bleu)
    }
}
