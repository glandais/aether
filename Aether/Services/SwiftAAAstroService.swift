import Foundation
import SwiftAA

/// Implémentation d'`AstroService` adossée à SwiftAA (algorithmes de Meeus).
/// Calcule la position apparente du soleil et de la lune en coordonnées
/// horizontales, convertie dans la convention d'Aether (azimut depuis le Nord,
/// sens horaire ; radians).
struct SwiftAAAstroService: AstroService {
    func position(
        of body: CelestialPosition.Body,
        at coordinate: GeoCoordinate,
        date: Date
    ) -> CelestialPosition {
        let julianDay = JulianDay(date)
        // SwiftAA attend une longitude « positivement vers l'ouest » (Meeus),
        // alors que GeoCoordinate suit la convention GPS (Est positif).
        let location = GeographicCoordinates(
            positivelyWestwardLongitude: Degree(-coordinate.longitude),
            latitude: Degree(coordinate.latitude)
        )

        let horizontal: HorizontalCoordinates
        switch body {
        case .sun:
            horizontal = Sun(julianDay: julianDay).makeHorizontalCoordinates(with: location)
        case .moon:
            horizontal = Moon(julianDay: julianDay).makeHorizontalCoordinates(with: location)
        }

        // `azimuth` de SwiftAA est mesuré depuis le Sud ; on prend la version
        // depuis le Nord, puis on convertit en radians.
        let degreesToRadians = Double.pi / 180.0
        return CelestialPosition(
            body: body,
            azimuth: horizontal.northBasedAzimuth.value * degreesToRadians,
            altitude: horizontal.altitude.value * degreesToRadians
        )
    }
}
