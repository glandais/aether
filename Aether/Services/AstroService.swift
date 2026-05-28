import Foundation

/// Positions du soleil et de la lune. Masque SwiftAA (ou une impl. Meeus interne).
protocol AstroService: Sendable {
    func position(
        of body: CelestialPosition.Body,
        at coordinate: GeoCoordinate,
        date: Date
    ) -> CelestialPosition

    /// Fraction éclairée de la Lune (0 = nouvelle, 1 = pleine) à l'instant donné.
    func moonIlluminatedFraction(date: Date) -> Double

    /// Éphéméride du jour au lieu donné : lever / coucher du Soleil et de la
    /// Lune, phase et fraction éclairée.
    func ephemeris(at coordinate: GeoCoordinate, date: Date) -> Ephemeris
}
