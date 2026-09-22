import Foundation

/// Mise en forme partagée d'une heure d'horloge « HH:mm » **24 h**, quelle que
/// soit la locale (choix délibéré : le ciel se lit en heure astronomique, sans
/// AM/PM). Utilisé par la barre temporelle du canvas et par l'éphéméride.
///
/// `Date.VerbatimFormatStyle` garantit le cycle 24 h (`.twentyFourHour`,
/// `.zeroBased` → 00…23) là où `.hour(.twoDigits(amPM: .omitted))` suivrait la
/// préférence 12/24 h de la locale (« 06:30 » pour 18 h 30 en `en_US`). Le style
/// est une petite valeur ; le formateur ICU sous-jacent est mis en cache par
/// Foundation, donc pas d'allocation lourde par passe de `body`.
enum ClockTime {
    /// Heure locale « HH:mm » (24 h) de `date` dans le fuseau `timeZone`.
    static func format(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(style(timeZone: timeZone))
    }

    /// Style 24 h explicite : fuseau et calendrier grégorien fixés, locale
    /// neutre (chiffres latins, comme l'ancien `en_US_POSIX`).
    private static func style(timeZone: TimeZone) -> Date.VerbatimFormatStyle {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone,
            calendar: calendar)
    }
}
