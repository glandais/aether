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
        /// Tangage (radians) reconstruit depuis l'`AccelerationVector` Apple.
        var pitch: Double?
        /// Roulis résiduel (radians) après redressement EXIF.
        var roll: Double?
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
            fieldOfView: fieldOfView,
            pitch: metadata.pitch ?? 0,
            roll: metadata.roll ?? 0
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
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let acceleration = accelerationVector(properties)
        return Metadata(
            coordinate: coordinate,
            date: date,
            heading: heading(properties),
            focalLength35: focalLength35(properties),
            pitch: acceleration.flatMap { pitch(fromAccelerationVector: $0) },
            roll: acceleration.flatMap { roll(fromAccelerationVector: $0, orientation: orientation) }
        )
    }

    /// `AccelerationVector` (MakerNote Apple, clé "8") : vecteur 3D « haut »
    /// (opposé à la gravité) dans le repère appareil [x gauche, y bas, z arrière].
    static func accelerationVector(_ properties: [CFString: Any]) -> [Double]? {
        guard let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
              let raw = maker["8"] as? [Any] else {
            return nil
        }
        let values = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        return values.count == 3 ? values : nil
    }

    /// Tangage depuis le vecteur « haut » : `asin(z)`. Robuste à l'orientation
    /// (la rotation portrait/paysage est autour de Z, ne change pas z).
    static func pitch(fromAccelerationVector vector: [Double]) -> Double? {
        guard vector.count == 3 else { return nil }
        let norm = (vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]).squareRoot()
        guard norm > 1e-6 else { return nil }
        return asin(max(-1.0, min(1.0, vector[2] / norm)))
    }

    /// Roulis résiduel : `atan2(x, -y)` (inclinaison dans le repère portrait)
    /// moins la rotation cardinale du redressement EXIF. Convention validée sur
    /// photos iPhone réelles pour les orientations 1 (paysage) et 6 (portrait) ;
    /// 3 et 8 inférées par symétrie.
    static func roll(fromAccelerationVector vector: [Double], orientation: UInt32) -> Double? {
        guard vector.count == 3 else { return nil }
        let raw = atan2(vector[0], -vector[1])
        let cardinal: Double
        switch orientation {
        case 3, 4: cardinal = .pi / 2     // paysage (home à gauche)
        case 5, 6: cardinal = 0           // portrait (validé : IMG_0793/0807)
        case 7, 8: cardinal = .pi         // portrait inversé
        default: cardinal = -.pi / 2      // 1, 2 — paysage (validé : IMG_0792)
        }
        var residual = raw - cardinal
        while residual > .pi { residual -= 2 * .pi }
        while residual < -.pi { residual += 2 * .pi }
        return residual
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
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        // L'iPhone écrit le décalage civil exact (`OffsetTimeOriginal`, ex.
        // "+02:00") : on l'utilise pour obtenir l'UTC précis.
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
           let timeZone = Self.timeZone(fromOffset: offset) {
            formatter.timeZone = timeZone
            return formatter.date(from: string)
        }

        // Repli : on approxime le fuseau par la longitude (heure solaire moyenne).
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let local = formatter.date(from: string) else {
            return nil
        }
        let offsetHours = (longitude ?? 0) / 15.0
        return local.addingTimeInterval(-offsetHours * 3600)
    }

    /// Convertit un décalage EXIF "+02:00" / "-05:00" en `TimeZone`.
    static func timeZone(fromOffset offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, let sign = trimmed.first,
              sign == "+" || sign == "-" else {
            return nil
        }
        let parts = trimmed.dropFirst().split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else {
            return nil
        }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func orientedImage(_ image: CGImage, properties: [CFString: Any]) -> CGImage? {
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation != 1 else { return image }
        let ciImage = CIImage(cgImage: image)
            .oriented(forExifOrientation: Int32(orientation))
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }
}
