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
}
