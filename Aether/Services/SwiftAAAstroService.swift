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

    func moonIlluminatedFraction(date: Date) -> Double {
        Moon(julianDay: JulianDay(date)).illuminatedFraction()
    }

    func ephemeris(at coordinate: GeoCoordinate, date: Date) -> Ephemeris {
        let julianDay = JulianDay(date)
        let location = GeographicCoordinates(
            positivelyWestwardLongitude: Degree(-coordinate.longitude),
            latitude: Degree(coordinate.latitude)
        )
        // Lever/coucher du jour : SwiftAA ancre le calcul à minuit UT du jour de
        // la `julianDay` fournie et renvoie `nil` quand l'astre est circumpolaire
        // ou ne franchit pas l'horizon ce jour-là.
        let sun = RiseTransitSetTimes(
            celestialBody: Sun(julianDay: julianDay), geographicCoordinates: location)
        let moon = RiseTransitSetTimes(
            celestialBody: Moon(julianDay: julianDay), geographicCoordinates: location)

        return Ephemeris(
            sun: Self.riseSetState(sun),
            moon: Self.riseSetState(moon),
            moonPhase: Self.moonPhase(julianDay: julianDay),
            moonIllumination: Moon(julianDay: julianDay).illuminatedFraction()
        )
    }

    /// Traduit les temps SwiftAA en `RiseSetState`. Lever **et** coucher absents
    /// ⇒ astre circumpolaire : au-dessus ou sous l'horizon selon `transitError`
    /// (cas des hautes latitudes : soleil de minuit / nuit polaire).
    private static func riseSetState(_ times: RiseTransitSetTimes) -> RiseSetState {
        if times.riseTime == nil, times.setTime == nil {
            return times.transitError == .alwaysAboveAltitude ? .alwaysUp : .alwaysDown
        }
        return .rises(rise: times.riseTime?.date, set: times.setTime?.date)
    }

    /// Phase en huit, depuis l'écart de longitude écliptique Lune − Soleil
    /// (l'« âge » angulaire) : 0° nouvelle, 90° premier quartier, 180° pleine,
    /// 270° dernier quartier. Distingue donc croissante (0→180) de décroissante.
    private static func moonPhase(julianDay: JulianDay) -> LunarPhase {
        let moonLongitude = Moon(julianDay: julianDay).apparentEclipticCoordinates.celestialLongitude.value
        let sunLongitude = Sun(julianDay: julianDay).apparentEclipticCoordinates.celestialLongitude.value
        var age = (moonLongitude - sunLongitude).truncatingRemainder(dividingBy: 360)
        if age < 0 { age += 360 }
        switch age {
        case ..<22.5: return .newMoon
        case ..<67.5: return .waxingCrescent
        case ..<112.5: return .firstQuarter
        case ..<157.5: return .waxingGibbous
        case ..<202.5: return .fullMoon
        case ..<247.5: return .waningGibbous
        case ..<292.5: return .lastQuarter
        case ..<337.5: return .waningCrescent
        default: return .newMoon
        }
    }
}
