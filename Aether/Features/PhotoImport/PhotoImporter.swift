import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Importe une photo personnelle : décode l'image, en lit les métadonnées EXIF
/// (GPS + horodatage) pour situer la scène, et estime sa profondeur via le
/// `DepthService`. Produit un `SceneContext` prêt à peindre.
struct PhotoImporter {
    enum ImportError: Error {
        case decodeFailed
    }

    /// Métadonnées extraites de l'EXIF d'une photo.
    struct Metadata: Equatable {
        var coordinate: GeoCoordinate?
        var date: Date?
        /// Cap de prise de vue (radians, 0 = Nord), si `GPSImgDirection` présent.
        var heading: Double?
        /// Focale 35 mm équivalente (mm), si présente. Le FOV en découle, mais
        /// dépend de l'orientation de la photo (calculé dans `makeContext`).
        var focalLength35: Double?
    }

    private let depthService: DepthService
    /// Lieu de repli si la photo n'a pas de GPS (Paris).
    private let fallbackCoordinate = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)

    init(depthService: DepthService) {
        self.depthService = depthService
    }

    func makeContext(from data: Data) async throws -> SceneContext {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImportError.decodeFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let oriented = Self.orientedImage(decoded, properties: properties) ?? decoded
        let metadata = Self.parseMetadata(properties)

        // FOV vertical selon l'orientation effective de la photo (après EXIF).
        let aspect = Double(oriented.width) / Double(max(oriented.height, 1))
        let fieldOfView = metadata.focalLength35.map {
            Self.verticalFieldOfView(focalLength35: $0, aspect: aspect)
        } ?? Scene.defaultFieldOfView

        let scene = Scene(
            title: "Photo",
            coordinate: metadata.coordinate ?? fallbackCoordinate,
            date: metadata.date ?? Date(),
            heading: metadata.heading ?? 0,
            fieldOfView: fieldOfView
        )
        // La profondeur est optionnelle : sans elle, pas d'occlusion par le relief.
        let depthMap = try? await depthService.estimateDepth(for: oriented)
        return SceneContext(
            scene: scene, landscape: oriented, depthMap: depthMap,
            displayAspect: CGFloat(aspect))
    }

    /// FOV vertical depuis la focale 35 mm. Le cadre 24×36 a 36 mm sur son grand
    /// axe : en paysage la verticale = 24 mm (demi 12), en portrait = 36 mm
    /// (demi 18). Approximation suffisante pour caler l'échelle du ciel.
    static func verticalFieldOfView(focalLength35: Double, aspect: Double) -> Double {
        guard focalLength35 > 0 else { return Scene.defaultFieldOfView }
        let halfSensor = aspect >= 1 ? 12.0 : 18.0
        return 2.0 * atan(halfSensor / focalLength35)
    }

    // MARK: - EXIF (pur, testable)

    /// Lit GPS et horodatage. L'heure EXIF est une heure locale (sans fuseau) ;
    /// on l'approxime en UTC via la longitude (≈ longitude / 15 h) quand un GPS
    /// est présent — suffisant pour positionner le soleil de façon plausible.
    static func parseMetadata(_ properties: [CFString: Any]) -> Metadata {
        let coordinate = gpsCoordinate(properties)
        let date = timestamp(properties, longitude: coordinate?.longitude)
        return Metadata(
            coordinate: coordinate,
            date: date,
            heading: heading(properties),
            focalLength35: focalLength35(properties)
        )
    }

    /// Cap de prise de vue depuis `GPSImgDirection` (degrés → radians).
    private static func heading(_ properties: [CFString: Any]) -> Double? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let direction = gps[kCGImagePropertyGPSImgDirection] as? Double else {
            return nil
        }
        return direction * .pi / 180.0
    }

    /// Focale 35 mm équivalente depuis l'EXIF.
    private static func focalLength35(_ properties: [CFString: Any]) -> Double? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double,
              focal35 > 0 else {
            return nil
        }
        return focal35
    }

    private static func gpsCoordinate(_ properties: [CFString: Any]) -> GeoCoordinate? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }
        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return GeoCoordinate(
            latitude: latitudeRef == "S" ? -latitude : latitude,
            longitude: longitudeRef == "W" ? -longitude : longitude
        )
    }

    private static func timestamp(_ properties: [CFString: Any], longitude: Double?) -> Date? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let string = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let local = formatter.date(from: string) else {
            return nil
        }
        // Convertit l'heure locale (lue comme UTC) en UTC réel via la longitude.
        let offsetHours = (longitude ?? 0) / 15.0
        return local.addingTimeInterval(-offsetHours * 3600)
    }

    private static func orientedImage(_ image: CGImage, properties: [CFString: Any]) -> CGImage? {
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation != 1 else { return image }
        let ciImage = CIImage(cgImage: image)
            .oriented(forExifOrientation: Int32(orientation))
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }
}
