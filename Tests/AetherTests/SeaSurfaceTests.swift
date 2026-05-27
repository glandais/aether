import Testing
@testable import Aether

/// Valide la surface de mer (Domain pur) et sa propagation depuis un paysage
/// curé vers le `SceneContext` consommé par le `Renderer`.
struct SeaSurfaceTests {
    @Test("Pas de mer par défaut, mer calme activée")
    func presets() {
        #expect(SeaSurface.none.enabled == false)
        #expect(SeaSurface.calm.enabled == true)
    }

    @Test("La mer calme est plus douce que les valeurs d'origine (contemplatif)")
    func calmIsGentle() {
        // Valeurs « Seascape » d'origine : choppy 4.0, speed 0.8. Le registre
        // contemplatif impose une houle plus lente et moins hachée.
        #expect(SeaSurface.calm.choppy < 4.0)
        #expect(SeaSurface.calm.speed < 0.8)
    }

    @Test("Un paysage curé sans mer produit un contexte terrestre")
    func landscapeWithoutSeaIsLand() throws {
        let land = CuratedLandscape(
            title: "Test", palette: LandscapeFactory.Palette(
                ground: .init(gray: 0.1, alpha: 1), horizon: .init(gray: 0.5, alpha: 1),
                skyLow: .init(gray: 0.6, alpha: 1), skyHigh: .init(gray: 0.2, alpha: 1)),
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            date: .init(timeIntervalSince1970: 0),
            weather: WeatherSnapshot(
                condition: .clear, cloudCover: 0.1, humidity: 0.4,
                windSpeed: 1, temperature: 20))
        let context = try #require(land.makeContext())
        #expect(context.sea.enabled == false)
    }

    @Test("Un paysage curé avec mer la transporte dans le contexte")
    func landscapeWithSeaPropagates() throws {
        let coastal = CuratedLandscape(
            title: "Test", palette: LandscapeFactory.Palette(
                ground: .init(gray: 0.1, alpha: 1), horizon: .init(gray: 0.5, alpha: 1),
                skyLow: .init(gray: 0.6, alpha: 1), skyHigh: .init(gray: 0.2, alpha: 1)),
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            date: .init(timeIntervalSince1970: 0),
            weather: WeatherSnapshot(
                condition: .clear, cloudCover: 0.1, humidity: 0.4,
                windSpeed: 1, temperature: 20),
            sea: .calm)
        let context = try #require(coastal.makeContext())
        #expect(context.sea.enabled == true)
        #expect(context.sea == SeaSurface.calm)
    }
}
