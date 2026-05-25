import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Aether

/// Valide l'extraction des métadonnées EXIF (GPS + horodatage) d'une photo,
/// hors ligne, sur une image JPEG synthétique.
struct PhotoImporterTests {
    @Test("GPS Nord/Est extrait avec le bon signe")
    func parsesNorthEast() throws {
        let data = try Self.makeJPEG(
            latitude: 48.8566, latitudeRef: "N",
            longitude: 2.3522, longitudeRef: "E",
            dateTimeOriginal: "2026:05:25 19:15:00")
        let metadata = PhotoImporter.parseMetadata(Self.properties(of: data))

        let coordinate = try #require(metadata.coordinate)
        #expect(abs(coordinate.latitude - 48.8566) < 0.001)
        #expect(abs(coordinate.longitude - 2.3522) < 0.001)
        #expect(metadata.date != nil)
    }

    @Test("GPS Sud/Ouest extrait en valeurs négatives")
    func parsesSouthWest() throws {
        let data = try Self.makeJPEG(
            latitude: 33.8688, latitudeRef: "S",
            longitude: 151.2093, longitudeRef: "W",
            dateTimeOriginal: "2026:05:25 06:00:00")
        let metadata = PhotoImporter.parseMetadata(Self.properties(of: data))

        let coordinate = try #require(metadata.coordinate)
        #expect(coordinate.latitude < 0)
        #expect(coordinate.longitude < 0)
    }

    @Test("Sans EXIF, les métadonnées sont vides")
    func handlesMissingMetadata() throws {
        let data = try Self.makeJPEG(
            latitude: nil, latitudeRef: nil, longitude: nil, longitudeRef: nil,
            dateTimeOriginal: nil)
        let metadata = PhotoImporter.parseMetadata(Self.properties(of: data))

        #expect(metadata.coordinate == nil)
        #expect(metadata.date == nil)
    }

    @Test("Tangage/roulis depuis de vrais AccelerationVector iPhone")
    func attitudeFromRealAccelerationVectors() {
        // Valeurs lues sur de vraies photos (dossier photos/).
        // IMG_0793 — portrait (orientation 6), tenu droit, légèrement vers le haut.
        let portrait = [-0.005157812, -0.9862852, 0.07311174]
        let portraitPitch = PhotoImporter.pitch(fromAccelerationVector: portrait)!
        let portraitRoll = PhotoImporter.roll(fromAccelerationVector: portrait, orientation: 6)!
        #expect(abs(portraitPitch * 180 / .pi - 4.2) < 1.0)   // ≈ 4°
        #expect(abs(portraitRoll) < 0.05)                      // tenu droit → ~0

        // IMG_0792 — paysage (orientation 1), ultra grand-angle visé vers le haut.
        let landscape = [-0.9252198, 0.010612, 0.367022]
        let landscapePitch = PhotoImporter.pitch(fromAccelerationVector: landscape)!
        let landscapeRoll = PhotoImporter.roll(fromAccelerationVector: landscape, orientation: 1)!
        #expect(abs(landscapePitch * 180 / .pi - 21.6) < 1.5)  // ≈ 22°
        #expect(abs(landscapeRoll) < 0.05)                      // tenu droit → ~0
    }

    @Test("Décalage EXIF +02:00 → fuseau correct")
    func parsesUTCOffset() throws {
        let timeZone = try #require(PhotoImporter.timeZone(fromOffset: "+02:00"))
        #expect(timeZone.secondsFromGMT() == 7200)
        let negative = try #require(PhotoImporter.timeZone(fromOffset: "-05:00"))
        #expect(negative.secondsFromGMT() == -18000)
    }

    @Test("Le FOV vertical dépend de l'orientation et du zoom")
    func fieldOfViewByOrientationAndZoom() {
        let focal = 26.0  // grand-angle typique de téléphone
        let landscape = PhotoImporter.verticalFieldOfView(focalLength35: focal, aspect: 3.0 / 2.0)
        let portrait = PhotoImporter.verticalFieldOfView(focalLength35: focal, aspect: 2.0 / 3.0)
        let telephoto = PhotoImporter.verticalFieldOfView(focalLength35: 77.0, aspect: 3.0 / 2.0)

        // En portrait, l'axe vertical utilise le grand côté du capteur → FOV plus large.
        #expect(portrait > landscape)
        // Plus longue focale (téléobjectif) → FOV plus étroit.
        #expect(telephoto < landscape)
    }

    // MARK: - Fabrique d'images de test

    private static func properties(of data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private static func makeJPEG(
        latitude: Double?, latitudeRef: String?,
        longitude: Double?, longitudeRef: String?,
        dateTimeOriginal: String?
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!

        var properties: [CFString: Any] = [:]
        if let latitude, let longitude {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: latitude,
                kCGImagePropertyGPSLatitudeRef: latitudeRef ?? "N",
                kCGImagePropertyGPSLongitude: longitude,
                kCGImagePropertyGPSLongitudeRef: longitudeRef ?? "E"
            ] as [CFString: Any]
        }
        if let dateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal
            ] as [CFString: Any]
        }

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return output as Data
    }
}
