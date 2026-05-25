import Testing
@testable import Aether

/// Valide le mapping météo → paramètres de nuage (étape 9). Pur et hors ligne :
/// le `WeatherService` (réseau) n'est pas sollicité ici.
struct CloudParametersTests {
    @Test("Un ciel couvert et humide donne des nuages pleins et opaques")
    func overcastIsDenseAndFull() {
        let overcast = WeatherSnapshot(
            condition: .overcast, cloudCover: 0.95, humidity: 0.9,
            windSpeed: 4, temperature: 12)
        let parameters = CloudParameters(weather: overcast)

        #expect(parameters.coverageBias > 0.1)
        #expect(parameters.densityScale > 1.2)
    }

    @Test("Un ciel dégagé et sec donne des nuages clairsemés et fins")
    func clearIsSparseAndThin() {
        let clear = WeatherSnapshot(
            condition: .clear, cloudCover: 0.05, humidity: 0.3,
            windSpeed: 2, temperature: 24)
        let parameters = CloudParameters(weather: clear)

        #expect(parameters.coverageBias < 0.0)
        #expect(parameters.densityScale < 0.9)
    }

    @Test("Plus de couverture → plus de densité (monotone)")
    func coverageIncreasesDensity() {
        func density(forCover cover: Double) -> Float {
            CloudParameters(weather: WeatherSnapshot(
                condition: .cloudy, cloudCover: cover, humidity: 0.6,
                windSpeed: 3, temperature: 15)).densityScale
        }
        #expect(density(forCover: 0.2) < density(forCover: 0.8))
    }
}
