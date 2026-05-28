import CoreLocation

/// Échecs de localisation remontés par `CoreLocationService`.
enum LocationError: Error {
    /// L'utilisateur a refusé l'accès à la position (ou il est restreint).
    case denied
}

/// Implémentation CoreLocation de `LocationService` : autorisation « quand l'app
/// est active » puis un point unique. Masque CoreLocation derrière le protocole
/// (cf. CLAUDE.md). `@MainActor` : le `CLLocationManager` et ses callbacks de
/// délégué vivent sur le thread principal.
@MainActor
final class CoreLocationService: NSObject, LocationService {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<GeoCoordinate, Error>?

    override init() {
        super.init()
        manager.delegate = self
        // Le kilomètre suffit largement pour orienter le ciel (le Soleil ne
        // bouge pas à l'échelle d'une ville) et accélère la prise de point.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentCoordinate() async throws -> GeoCoordinate {
        let status = await authorize()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw LocationError.denied
        }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    /// Statut courant, en demandant l'autorisation si elle n'est pas déterminée.
    private func authorize() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            authContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }
}

extension CoreLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // On ne reprend qu'une réponse explicite à notre demande en attente.
            guard status != .notDetermined, let continuation = authContinuation else { return }
            authContinuation = nil
            continuation.resume(returning: status)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        let coordinate = GeoCoordinate(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        Task { @MainActor in
            locationContinuation?.resume(returning: coordinate)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        Task { @MainActor in
            locationContinuation?.resume(throwing: error)
            locationContinuation = nil
        }
    }
}
