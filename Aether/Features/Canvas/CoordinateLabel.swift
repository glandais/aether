import Foundation

/// Mise en forme partagée d'une coordonnée compacte, ex. « 48.9°N, 2.4°E ».
/// Les abréviations cardinales sont localisées (fr : « O » pour ouest) via la
/// table `Aether`. Utilisé par le label du canvas et par la feuille de choix
/// du lieu — une seule source de vérité pour éviter la divergence.
enum CoordinateLabel {
    /// Formate une paire latitude/longitude en degrés décimaux.
    static func format(latitude: Double, longitude: Double) -> String {
        let lat = component(abs(latitude), suffix: latitude >= 0 ? .north : .south)
        let lon = component(abs(longitude), suffix: longitude >= 0 ? .east : .west)
        return "\(lat), \(lon)"
    }

    /// Un degré décimal suivi de son abréviation cardinale localisée.
    private static func component(_ degrees: Double, suffix: Cardinal) -> String {
        String(format: "%.1f°%@", degrees, suffix.abbreviation)
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
