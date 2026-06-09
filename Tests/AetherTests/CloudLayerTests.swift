import Foundation
import Testing
import simd
@testable import Aether

/// Valide le modèle Domain des multi-coquilles peintes (cf. `docs/SHELLS.md`
/// §4) : cohérence des rayons par genre, ordre des étages, profil `cloudType`,
/// borne de calques et aller-retour `Codable`. Type pur, sans rendu.
struct CloudLayerTests {
    @Test("Chaque coquille a un rayon interne strictement sous l'externe")
    func shellInnerBelowOuter() {
        for genus in CloudGenus.allCases {
            let shell = genus.shell
            #expect(shell.inner < shell.outer)
        }
    }

    @Test("Les étages montent strictement et restent disjoints : cumulus < altocumulus < cirrus")
    func stagesAreStrictlyAscendingAndDisjoint() {
        let cumulus = CloudGenus.cumulus.shell
        let alto = CloudGenus.altocumulus.shell
        let cirrus = CloudGenus.cirrus.shell

        // Étages ordonnés en altitude.
        #expect(cumulus.inner < alto.inner)
        #expect(alto.inner < cirrus.inner)

        // Disjoints : le haut d'un étage passe sous le bas du suivant.
        #expect(cumulus.outer < alto.inner)
        #expect(alto.outer < cirrus.inner)
    }

    @Test("cloudType croît du cirrus (stratiforme) au cumulus (bourgeonnant)")
    func cloudTypeAscendsFromCirrusToCumulus() {
        #expect(CloudGenus.cirrus.shell.cloudType < CloudGenus.altocumulus.shell.cloudType)
        #expect(CloudGenus.altocumulus.shell.cloudType < CloudGenus.cumulus.shell.cloudType)
    }

    @Test("noiseScale en coordonnées planète (~3e-4), pas le 0.42 des cubes")
    func noiseScaleIsInPlanetCoordinates() {
        // Ordre de grandeur ~10⁻⁴ : très loin du kNoiseScale = 0.42 des cubes.
        for genus in CloudGenus.allCases {
            let scale = genus.shell.noiseScale
            #expect(scale > 1e-4)
            #expect(scale < 1e-3)
        }
    }

    @Test("CloudLayer fait un aller-retour Codable à l'identique")
    func layerCodableRoundTrips() throws {
        let camera = StrokeCamera(
            right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, -1),
            tanHalfFov: 0.5, aspect: 1.5)
        let stroke = BrushStroke(
            points: [SIMD2(0.4, 0.6), SIMD2(0.55, 0.62)],
            radius: 0.12, softness: 0.3, camera: camera)
        let layer = CloudLayer(
            genus: .altocumulus, strokes: [stroke],
            coverageBias: 0.15, opacity: 0.8, isVisible: false)

        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(CloudLayer.self, from: data)

        #expect(decoded == layer)
    }

    @Test("maxCount borne le nombre de calques (un par étage + marge)")
    func maxCountAllowsAllGenresPlusMargin() {
        #expect(CloudLayer.maxCount == 4)
        #expect(CloudLayer.maxCount >= CloudGenus.allCases.count)
    }
}
