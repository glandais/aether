/// Coordonnée géographique pure — découple le Domain de CoreLocation.
struct GeoCoordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}
