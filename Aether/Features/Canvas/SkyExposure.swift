import CoreGraphics

/// Estime l'exposition d'un paysage : la luminance moyenne de l'image,
/// rehaussée vers le point blanc. Sert à caler la luminosité du nuage sur celle
/// de la photo (un nuage dans un ciel lumineux est lumineux ; au crépuscule,
/// sombre). Approximation suffisante, robuste à l'orientation.
enum SkyExposure {
    static func estimate(from image: CGImage) -> Float {
        let width = 16
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0.6
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0.6 }

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum: Float = 0
        for i in 0..<(width * height) {
            let r = Float(pixels[i * 4])
            let g = Float(pixels[i * 4 + 1])
            let b = Float(pixels[i * 4 + 2])
            sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
        }
        let average = sum / Float(width * height)
        // Rehausse vers le point blanc (le sol/relief sombre tire la moyenne bas).
        return min(max(average * 1.6, 0.15), 1.0)
    }
}
