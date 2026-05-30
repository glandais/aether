/// Coordonnée géographique pure — découple le Domain de CoreLocation.
struct GeoCoordinate: Equatable, Sendable, Codable {
    var latitude: Double
    var longitude: Double
}
