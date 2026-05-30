import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodage PNG d'un `CGImage` pour l'embarquer dans un document `.aether`
/// (le paysage curé est procédural : aucune référence stable, on stocke l'image).
extension CGImage {
    /// Encode l'image en PNG. `nil` si l'encodage échoue (rare).
    func pngData() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Décode un PNG (ou tout format reconnu par ImageIO) vers un `CGImage`.
    static func from(pngData data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
