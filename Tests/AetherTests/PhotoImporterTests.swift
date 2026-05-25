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
