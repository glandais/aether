import Foundation

/// Mise en forme partagée d'une coordonnée compacte, ex. « 48.9°N, 2.4°E » (en)
/// ou « 48,9°N ; 2,4°E » (fr). Les degrés suivent le séparateur décimal de la
/// locale, et le séparateur de la paire aussi (« ; » quand la décimale est une
/// virgule, quelle que soit la langue de l'app) ; les abréviations cardinales
/// (fr : « O » pour ouest) sont localisées via la table `Aether`. Utilisé par le
/// label du canvas et par la feuille de choix du lieu — une seule source de vérité pour éviter la divergence.
enum CoordinateLabel {
    /// Formate une paire latitude/longitude en degrés décimaux.
    static func format(latitude: Double, longitude: Double) -> String {
        let lat = component(abs(latitude), suffix: latitude >= 0 ? .north : .south)
        let lon = component(abs(longitude), suffix: longitude >= 0 ? .east : .west)
        return lat + pairSeparator + lon
    }

    /// Séparateur de la paire, choisi d'après la **locale** (comme les degrés)
    /// et non la langue : « ; » si la décimale est une virgule, pour que
    /// « 48,9°N ; 2,4°E » reste non ambigu (ex. app en anglais, région France).
    private static var pairSeparator: String {
        Locale.current.decimalSeparator == "," ? " ; " : ", "
    }

    /// Un degré décimal (1 décimale, séparateur de la locale) suivi de son
    /// abréviation cardinale localisée.
    private static func component(_ degrees: Double, suffix: Cardinal) -> String {
        degrees.formatted(.number.precision(.fractionLength(1))) + "°" + suffix.abbreviation
    }

    /// Point cardinal et son abréviation localisée (table `Aether`).
    private enum Cardinal {
        case north, south, east, west

        var abbreviation: String {
            switch self {
            case .north: String(localized: "compass.north", table: "Aether")
            case .south: String(localized: "compass.south", table: "Aether")
            case .east: String(localized: "compass.east", table: "Aether")
            case .west: String(localized: "compass.west", table: "Aether")
            }
        }
    }
}
