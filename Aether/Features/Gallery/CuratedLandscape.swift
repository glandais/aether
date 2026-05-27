import CoreGraphics
import Foundation

/// Un paysage curé (procédural pour l'instant) : palette + lieu + instant +
/// météo statique. Produit un `SceneContext` prêt à peindre.
struct CuratedLandscape: Identifiable {
    let id = UUID()
    let title: String
    let palette: LandscapeFactory.Palette
    let coordinate: GeoCoordinate
    let date: Date
    /// Météo figée du paysage (plus de récupération réseau) : informe la
    /// couverture et l'opacité initiales du nuage peint.
    let weather: WeatherSnapshot

    func makeContext() -> SceneContext? {
        guard let image = LandscapeFactory.image(palette: palette) else { return nil }
        let scene = Scene(
            title: title, coordinate: coordinate, date: date,
            utcOffset: coordinate.longitude / 15.0 * 3600.0)  // approx. via longitude
        // Paysages curés abstraits : plein cadre (displayAspect nil).
        return SceneContext(
            scene: scene, landscape: image, displayAspect: nil,
            skyExposure: SkyExposure.estimate(from: image),
            cloudParameters: CloudParameters(weather: weather))
    }
}

extension CuratedLandscape {
    /// Galerie curée par défaut — registre sobre et atmosphérique.
    static let catalog: [CuratedLandscape] = [
        CuratedLandscape(
            title: "Crépuscule",
            palette: LandscapeFactory.Palette(
                ground: gray(0.07), horizon: rgb(0.96, 0.64, 0.40),
                skyLow: rgb(0.46, 0.33, 0.40), skyHigh: rgb(0.10, 0.13, 0.25)),
            coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522),  // Paris
            date: utc(2026, 5, 25, 19, 15),
            weather: WeatherSnapshot(
                condition: .partlyCloudy, cloudCover: 0.45, humidity: 0.65,
                windSpeed: 3, temperature: 16)),
        CuratedLandscape(
            title: "Aube",
            palette: LandscapeFactory.Palette(
                ground: gray(0.08), horizon: rgb(0.98, 0.80, 0.62),
                skyLow: rgb(0.62, 0.66, 0.78), skyHigh: rgb(0.30, 0.45, 0.66)),
            coordinate: GeoCoordinate(latitude: 35.0116, longitude: 135.7681),  // Kyoto
            date: utc(2026, 5, 25, 20, 0),
            weather: WeatherSnapshot(
                condition: .clear, cloudCover: 0.20, humidity: 0.55,
                windSpeed: 2, temperature: 14)),
        CuratedLandscape(
            title: "Heure bleue",
            palette: LandscapeFactory.Palette(
                ground: gray(0.05), horizon: rgb(0.40, 0.36, 0.52),
                skyLow: rgb(0.20, 0.26, 0.46), skyHigh: rgb(0.06, 0.09, 0.22)),
            coordinate: GeoCoordinate(latitude: 64.1466, longitude: -21.9426),  // Reykjavik
            date: utc(2026, 5, 25, 22, 30),
            weather: WeatherSnapshot(
                condition: .overcast, cloudCover: 0.85, humidity: 0.80,
                windSpeed: 8, temperature: 7)),
        CuratedLandscape(
            title: "Plein midi",
            palette: LandscapeFactory.Palette(
                ground: gray(0.10), horizon: rgb(0.78, 0.82, 0.86),
                skyLow: rgb(0.46, 0.62, 0.82), skyHigh: rgb(0.20, 0.42, 0.74)),
            coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093),  // Sydney
            date: utc(2026, 5, 25, 2, 0),
            weather: WeatherSnapshot(
                condition: .partlyCloudy, cloudCover: 0.30, humidity: 0.45,
                windSpeed: 5, temperature: 24))
    ]

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func gray(_ v: CGFloat) -> CGColor {
        CGColor(red: v, green: v, blue: v, alpha: 1)
    }

    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? Date()
    }
}
