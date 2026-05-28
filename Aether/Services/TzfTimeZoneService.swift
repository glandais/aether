import Foundation
import tzf

/// Résolution hors-ligne du fuseau d'un lieu via tzf (polygones de frontières
/// IANA). On en déduit un `TimeZone` nommé, dont la tzdata système porte l'heure
/// d'été.
///
/// `actor` pour porter sans risque le `DefaultFinder` (type non-`Sendable`) :
/// son init charge les polygones embarqués (coûteux), donc on le crée
/// paresseusement, une fois, à la première résolution.
actor TzfTimeZoneService: TimeZoneService {
    private var finder: DefaultFinder?

    func timeZone(for coordinate: GeoCoordinate) async -> TimeZone? {
        if finder == nil { finder = try? DefaultFinder() }
        // `getTimezone` attend des coordonnées GPS standard (longitude Est
        // positive) — pas d'inversion, contrairement à SwiftAA/Meeus.
        guard let identifier = try? finder?.getTimezone(
                lng: coordinate.longitude, lat: coordinate.latitude)
        else { return nil }
        return TimeZone(identifier: identifier)
    }
}
