import Foundation

/// Accès à la position de l'utilisateur. Masque CoreLocation.
protocol LocationService: Sendable {
    func currentCoordinate() async throws -> GeoCoordinate
}
