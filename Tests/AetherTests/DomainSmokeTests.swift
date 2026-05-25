import Foundation
import Testing
@testable import Aether

/// Test de fumée : valide la chaîne build/test sur les modèles Domain purs.
struct DomainSmokeTests {
    @Test("Une Scene conserve son lieu, son instant et son titre")
    func sceneHoldsValues() {
        let coordinate = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
        let date = Date(timeIntervalSince1970: 0)
        let scene = Scene(title: "Paris, aube", coordinate: coordinate, date: date)

        #expect(scene.coordinate == coordinate)
        #expect(scene.date == date)
        #expect(scene.title == "Paris, aube")
        #expect(scene.landscapeAssetName == nil)
    }
}
