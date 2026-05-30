import Foundation

/// Une scène : un paysage choisi, ancré à un lieu et un instant.
/// Type pur, sans logique — la résolution météo/astro vit dans les Services.
struct Scene: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var title: String
    /// Nom de l'asset du paysage curé, ou `nil` si photo personnelle importée.
    var landscapeAssetName: String?
    var coordinate: GeoCoordinate
    var date: Date
    /// Cap de la caméra qui a pris le paysage : radians, 0 = Nord, sens horaire
    /// (EXIF `GPSImgDirection`). Oriente le soleil relativement à la scène.
    var heading: Double
    /// Champ de vision vertical de la caméra, en radians (dérivé de la focale
    /// EXIF). Détermine l'échelle de projection du ciel sur la photo.
    var fieldOfView: Double
    /// Tangage de la caméra : radians, >0 = visée vers le haut. Reconstruit
    /// depuis l'`AccelerationVector` (MakerNote Apple) à l'import.
    var pitch: Double
    /// Roulis de la caméra : radians, inclinaison latérale résiduelle (après
    /// redressement EXIF). Reconstruit depuis l'`AccelerationVector`.
    var roll: Double
    /// Décalage UTC du lieu (secondes) : repli pour afficher/scruter l'heure
    /// locale quand aucun fuseau nommé n'est connu (EXIF `OffsetTimeOriginal`).
    var utcOffset: TimeInterval
    /// Identifiant IANA du fuseau du lieu (`Europe/Paris`…) : préféré à
    /// `utcOffset`, il porte l'heure d'été via la tzdata système. `nil` pour les
    /// photos importées (on retombe alors sur `utcOffset`).
    var timeZoneIdentifier: String?

    /// FOV vertical par défaut ≈ 53° (caméra grand-angle générique).
    static let defaultFieldOfView = 0.9273

    /// Fuseau résolu : tzdata système si un identifiant nommé est connu (DST
    /// inclus), sinon offset fixe `utcOffset`.
    var timeZone: TimeZone {
        if let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier) {
            return zone
        }
        return TimeZone(secondsFromGMT: Int(utcOffset)) ?? .gmt
    }

    init(
        id: UUID = UUID(),
        title: String,
        landscapeAssetName: String? = nil,
        coordinate: GeoCoordinate,
        date: Date,
        heading: Double = 0,
        fieldOfView: Double = Scene.defaultFieldOfView,
        pitch: Double = 0,
        roll: Double = 0,
        utcOffset: TimeInterval = 0,
        timeZoneIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.landscapeAssetName = landscapeAssetName
        self.coordinate = coordinate
        self.date = date
        self.heading = heading
        self.fieldOfView = fieldOfView
        self.pitch = pitch
        self.roll = roll
        self.utcOffset = utcOffset
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
