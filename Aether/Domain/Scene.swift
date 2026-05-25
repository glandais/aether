import Foundation

/// Une scène : un paysage choisi, ancré à un lieu et un instant.
/// Type pur, sans logique — la résolution météo/astro vit dans les Services.
struct Scene: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    /// Nom de l'asset du paysage curé, ou `nil` si photo personnelle importée.
    var landscapeAssetName: String?
    var coordinate: GeoCoordinate
    var date: Date

    init(
        id: UUID = UUID(),
        title: String,
        landscapeAssetName: String? = nil,
        coordinate: GeoCoordinate,
        date: Date
    ) {
        self.id = id
        self.title = title
        self.landscapeAssetName = landscapeAssetName
        self.coordinate = coordinate
        self.date = date
    }
}
