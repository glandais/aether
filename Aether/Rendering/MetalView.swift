import CoreGraphics
import MetalKit
import SwiftUI

/// Pont SwiftUI ↔ `MTKView`. Le `Renderer` (delegate) est conservé par le
/// Coordinator pour vivre aussi longtemps que la vue. Le paysage n'est
/// (ré)appliqué que lorsque le contenu change (`contentID`) ; les traits, le
/// soleil et la météo sont poussés à chaque mise à jour.
struct MetalView: UIViewRepresentable {
    var strokes: [BrushStroke]
    var sunDirection: SIMD3<Float>
    var skySunDirection: SIMD3<Float>
    var atmosphere: Atmosphere
    var groundLight: Float
    var sunColor: SIMD3<Float>
    var skyAmbient: SIMD3<Float>
    var cloudParameters: CloudParameters
    var sea: SeaSurface
    /// Direction monde de la lune + clair de lune, pour le reflet sur la mer.
    var moonSkyDirection: SIMD3<Float>
    var moonGlint: SIMD3<Float>
    var nightWeight: Float
    /// Radiance ciel zénith/horizon (intégrales CPU) pour le reflet de la mer.
    var skyZenithRadiance: SIMD3<Float>
    var skyHorizonRadiance: SIMD3<Float>
    var cameraTanHalfFov: Float
    /// Base caméra → monde (lacet + tangage du regard) pour le rayon de vue du ciel.
    var cameraRight: SIMD3<Float>
    var cameraUp: SIMD3<Float>
    var cameraForward: SIMD3<Float>
    var landscape: CGImage
    var contentID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        let renderer = Renderer(view: view)
        context.coordinator.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }

        if context.coordinator.appliedContentID != contentID {
            renderer.setLandscape(landscape)
            context.coordinator.appliedContentID = contentID
        }

        renderer.updateSunDirection(sunDirection)
        renderer.updateSky(sunDirection: skySunDirection, atmosphere: atmosphere, groundLight: groundLight)
        renderer.updateLighting(sunColor: sunColor, ambient: skyAmbient)
        renderer.updateCloudParameters(cloudParameters)
        renderer.updateSea(sea)
        renderer.updateMoon(direction: moonSkyDirection, glint: moonGlint, nightWeight: nightWeight)
        renderer.updateSeaSky(zenith: skyZenithRadiance, horizon: skyHorizonRadiance)
        renderer.updateFieldOfView(cameraTanHalfFov)
        renderer.updateCameraBasis(right: cameraRight, up: cameraUp, forward: cameraForward)
        renderer.updateStrokes(strokes)
    }

    @MainActor
    final class Coordinator {
        var renderer: Renderer?
        var appliedContentID: UUID?
    }
}
