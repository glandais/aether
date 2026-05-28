import Foundation

/// Résolution du fuseau horaire d'un lieu. Masque la dépendance externe (tzf).
protocol TimeZoneService: Sendable {
    /// Fuseau IANA du lieu (DST porté par la tzdata système), ou `nil` si la
    /// résolution échoue (coordonnée en mer, base indisponible…).
    func timeZone(for coordinate: GeoCoordinate) async -> TimeZone?
}
