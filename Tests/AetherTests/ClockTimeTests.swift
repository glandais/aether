import Foundation
import Testing
@testable import Aether

/// L'heure affichée (barre temporelle, éphéméride) est volontairement en 24 h,
/// quelle que soit la préférence 12/24 h de la locale, et dans le fuseau de la
/// scène (pas celui de l'appareil).
struct ClockTimeTests {
    /// 2026-06-21 16:30 UTC.
    private let instant = Date(timeIntervalSince1970: 1_782_059_400)

    @Test func formatsTwentyFourHourInSceneTimeZone() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(ClockTime.format(instant, timeZone: utc) == "16:30")
        #expect(ClockTime.format(instant, timeZone: paris) == "18:30")
        #expect(ClockTime.format(instant, timeZone: newYork) == "12:30")
    }

    @Test func midnightIsZeroBased() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // 16:30 UTC + 9 h → 01:30 ; 15:00 UTC → 00:00 à Tokyo.
        #expect(ClockTime.format(instant, timeZone: tokyo) == "01:30")
        let midnight = instant.addingTimeInterval(-5_400)
        #expect(ClockTime.format(midnight, timeZone: tokyo) == "00:00")
    }
}
