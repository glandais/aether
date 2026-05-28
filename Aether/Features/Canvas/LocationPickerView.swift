import MapKit
import SwiftUI

/// Choix du lieu de la scène : carte panoramiquée sous un pin fixe au centre.
/// Registre sobre — la coordonnée visée s'affiche en continu ; « Valider »
/// remonte le lieu choisi. Hors-ligne, les tuiles manquent mais la coordonnée
/// reste exacte.
struct LocationPickerView: View {
    let initial: GeoCoordinate
    let onCommit: (GeoCoordinate) -> Void
    private let locationService: LocationService

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    /// Coordonnée visée par le pin (centre de la carte), suivie en continu.
    @State private var center: CLLocationCoordinate2D
    /// Prise de position en cours (bouton « ma position »).
    @State private var isLocating = false

    init(
        initial: GeoCoordinate,
        locationService: LocationService = CoreLocationService(),
        onCommit: @escaping (GeoCoordinate) -> Void
    ) {
        self.initial = initial
        self.locationService = locationService
        self.onCommit = onCommit
        let coordinate = CLLocationCoordinate2D(
            latitude: initial.latitude, longitude: initial.longitude)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12))))
        _center = State(initialValue: coordinate)
    }

    var body: some View {
        NavigationStack {
            Map(position: $position)
                .onMapCameraChange(frequency: .continuous) { context in
                    center = context.region.center
                }
                .overlay { pin }
                .overlay(alignment: .bottomTrailing) { locateButton }
                .overlay(alignment: .bottom) { coordinateLabel }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("location.title", tableName: "Aether"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "action.cancel", table: "Aether")) {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "action.confirm", table: "Aether")) {
                            onCommit(GeoCoordinate(
                                latitude: center.latitude, longitude: center.longitude))
                            dismiss()
                        }
                    }
                }
        }
    }

    /// Recentre la carte sur la position actuelle de l'appareil (CoreLocation).
    private var locateButton: some View {
        Button(action: locate) {
            Group {
                if isLocating {
                    ProgressView()
                } else {
                    Image(systemName: "location.fill")
                }
            }
            .font(.headline)
            .foregroundStyle(.tint)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isLocating)
        .padding(.trailing, 16)
        .padding(.bottom, 28)
        .accessibilityLabel(Text("location.current", tableName: "Aether"))
    }

    /// Résout la position courante puis y recentre la carte (et le pin). Échec
    /// silencieux (refus, pas de fix) : la carte reste où elle est.
    private func locate() {
        isLocating = true
        Task {
            defer { isLocating = false }
            guard let coordinate = try? await locationService.currentCoordinate() else { return }
            let target = CLLocationCoordinate2D(
                latitude: coordinate.latitude, longitude: coordinate.longitude)
            center = target
            withAnimation {
                position = .region(MKCoordinateRegion(
                    center: target,
                    span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)))
            }
        }
    }

    /// Pin fixe : la pointe vise le centre exact de la carte (léger décalage haut).
    private var pin: some View {
        Image(systemName: "mappin")
            .font(.title)
            .foregroundStyle(.red)
            .shadow(radius: 3)
            .offset(y: -11)
            .allowsHitTesting(false)
    }

    private var coordinateLabel: some View {
        Text(Self.format(center))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 28)
    }

    /// Coordonnée compacte, ex. « 48.9°N, 2.4°E ».
    private static func format(_ coordinate: CLLocationCoordinate2D) -> String {
        let lat = String(
            format: "%.1f°%@", abs(coordinate.latitude), coordinate.latitude >= 0 ? "N" : "S")
        let lon = String(
            format: "%.1f°%@", abs(coordinate.longitude), coordinate.longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }
}
