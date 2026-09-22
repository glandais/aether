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
    /// Créé au premier usage seulement : le service peut être instancié souvent
    /// (valeur par défaut d'un `@State`, réévaluée à chaque init de vue puis
    /// jetée) alors qu'on ne demande la position que rarement.
    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        // Le kilomètre suffit largement pour orienter le ciel (le Soleil ne
        // bouge pas à l'échelle d'une ville) et accélère la prise de point.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return manager
    }()
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Error>?
    private var locationContinuation: CheckedContinuation<GeoCoordinate, Error>?
    /// Numéro de la demande propriétaire des continuations en attente : une
    /// annulation qui arrive en retard (saut asynchrone vers le main actor) ne
    /// doit pas rejeter la demande suivante.
    private var currentRequest = 0

    func currentCoordinate() async throws -> GeoCoordinate {
        // Une nouvelle demande remplace l'ancienne : ses continuations sont
        // reprises (annulées) avant d'être écrasées, jamais abandonnées.
        cancelPending()
        currentRequest += 1
        let request = currentRequest
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let status = try await authorize()
            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                throw LocationError.denied
            }
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                locationContinuation = continuation
                manager.requestLocation()
            }
        } onCancel: {
            // La tâche appelante est annulée : CoreLocation n'en sait rien, on
            // reprend nous-mêmes la continuation pendante de *cette* demande.
            Task { @MainActor [weak self] in
                guard let self, self.currentRequest == request else { return }
                self.cancelPending()
            }
        }
    }

    /// Statut courant, en demandant l'autorisation si elle n'est pas déterminée.
    private func authorize() async throws -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return try await withCheckedThrowingContinuation { continuation in
            authContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Reprend en `CancellationError` les continuations en attente (chacune
    /// doit être reprise exactement une fois).
    private func cancelPending() {
        authContinuation?.resume(throwing: CancellationError())
        authContinuation = nil
        locationContinuation?.resume(throwing: CancellationError())
        locationContinuation = nil
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
