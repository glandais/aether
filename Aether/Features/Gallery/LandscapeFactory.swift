import CoreGraphics

/// Génère les paysages curés *procéduraux* (placeholders atmosphériques) :
/// un dégradé vertical sobre + une depth map synthétique (ciel lointain, sol
/// proche). Remplacé plus tard par de vraies photos curées.
enum LandscapeFactory {
    /// Palette d'un paysage : du sol (bas) au ciel (haut).
    struct Palette {
        var ground: CGColor
        var horizon: CGColor
        var skyLow: CGColor
        var skyHigh: CGColor
    }

    static func image(palette: Palette, width: Int = 64, height: Int = 512) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // Origine CG en bas à gauche : du sol (y=0) vers le ciel (y=height).
        let colors = [palette.ground, palette.ground, palette.horizon, palette.skyLow, palette.skyHigh] as CFArray
        let locations: [CGFloat] = [0.0, 0.30, 0.34, 0.55, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            return nil
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: []
        )
        return context.makeImage()
    }
}
