import Foundation
import Testing
import simd
@testable import Aether

/// Valide la base caméra → monde de `CameraPose`. L'invariant central est la
/// **cohérence** avec `CelestialPosition.cameraDirection` (monde → caméra) : la
/// base doit en être la transposée, sinon le ciel panoramique et l'éclairage du
/// nuage divergeraient sous rotation du regard.
struct CameraPoseTests {
    private func approxEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tol: Float = 1e-4) -> Bool {
        length(a - b) < tol
    }

    @Test func identityBasisFacesNorth() {
        let basis = CameraPose(heading: 0, pitch: 0).basis
        #expect(approxEqual(basis.right, SIMD3(1, 0, 0)))
        #expect(approxEqual(basis.up, SIMD3(0, 1, 0)))
        #expect(approxEqual(basis.forward, SIMD3(0, 0, -1)))  // -Z = Nord
    }

    @Test func basisIsOrthonormal() {
        for heading in stride(from: -2.0, through: 2.0, by: 0.5) {
            for pitch in stride(from: -1.2, through: 1.2, by: 0.4) {
                let (right, up, forward) = CameraPose(heading: heading, pitch: pitch).basis
                #expect(abs(length(right) - 1) < 1e-4)
                #expect(abs(length(up) - 1) < 1e-4)
                #expect(abs(length(forward) - 1) < 1e-4)
                #expect(abs(dot(right, up)) < 1e-4)
                #expect(abs(dot(right, forward)) < 1e-4)
                #expect(abs(dot(up, forward)) < 1e-4)
            }
        }
    }

    @Test func yaw90LooksEast() {
        // Lacet +90° (sens horaire depuis le Nord) → regard vers l'Est (+X) ;
        // la droite de la caméra pointe vers le Sud (+Z).
        let basis = CameraPose(heading: .pi / 2, pitch: 0).basis
        #expect(approxEqual(basis.forward, SIMD3(1, 0, 0)))
        #expect(approxEqual(basis.right, SIMD3(0, 0, 1)))
    }

    @Test func positivePitchLooksUp() {
        let basis = CameraPose(heading: 0, pitch: 0.6).basis
        #expect(basis.forward.y > 0)  // viser vers le haut
    }

    /// Cœur du test : `cameraDirection` exprime une direction monde `d` dans le
    /// repère caméra (`c`, convention -Z avant). La reconstruction par la base
    /// doit redonner `d` : `d ≈ c.x·right + c.y·up − c.z·forward`.
    @Test func basisInvertsCameraDirection() {
        let sun = CelestialPosition(body: .sun, azimuth: 1.1, altitude: 0.4)
        for heading in stride(from: -2.0, through: 2.0, by: 0.7) {
            for pitch in stride(from: -1.0, through: 1.0, by: 0.5) {
                let d = sun.worldDirection
                let c = sun.cameraDirection(heading: heading, pitch: pitch)
                let (right, up, forward) = CameraPose(heading: heading, pitch: pitch).basis
                let reconstructed = c.x * right + c.y * up - c.z * forward
                #expect(approxEqual(reconstructed, d, tol: 1e-3))
            }
        }
    }
}
