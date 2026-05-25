import Testing
import WeatherKit
@testable import Aether

/// Mapping pur condition WeatherKit → condition Domain. Hors ligne : on
/// construit des valeurs d'enum, sans requête ni entitlement.
struct WeatherKitMappingTests {
    @Test("Les conditions WeatherKit principales mappent vers le Domain")
    func mapsRepresentativeConditions() {
        #expect(WeatherSnapshot.Condition(weatherKit: .clear) == .clear)
        #expect(WeatherSnapshot.Condition(weatherKit: .partlyCloudy) == .partlyCloudy)
        #expect(WeatherSnapshot.Condition(weatherKit: .cloudy) == .cloudy)
        #expect(WeatherSnapshot.Condition(weatherKit: .foggy) == .fog)
        #expect(WeatherSnapshot.Condition(weatherKit: .rain) == .rain)
        #expect(WeatherSnapshot.Condition(weatherKit: .snow) == .snow)
    }
}
