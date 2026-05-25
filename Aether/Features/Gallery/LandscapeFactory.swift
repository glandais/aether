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

    /// Depth map synthétique : ciel lointain en haut, relief proche en bas.
    /// Convention Domain : 0 = proche, 1 = lointain (ligne par ligne, haut→bas).
    static func depthMap(width: Int = 16, height: Int = 256) -> DepthMap {
        var values = [Float](repeating: 1, count: width * height)
        let horizon: Float = 0.58  // position de l'horizon (0 = haut)
        for row in 0..<height {
            let v = Float(row) / Float(height - 1)  // 0 = haut (ciel), 1 = bas (sol)
            // Ciel lointain (≈1) jusqu'à l'horizon, puis se rapproche vers le bas.
            let depth: Float
            if v < horizon {
                depth = 1.0
            } else {
                let t = (v - horizon) / (1.0 - horizon)
                depth = 1.0 - t  // 1 (lointain) → 0 (proche)
            }
            for col in 0..<width {
                values[row * width + col] = depth
            }
        }
        return DepthMap(width: width, height: height, values: values)
    }
}
