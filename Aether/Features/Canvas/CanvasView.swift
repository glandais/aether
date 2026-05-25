import Foundation
import SwiftUI
import simd

/// Hôte plein écran du canvas de rendu volumétrique, pour un paysage donné.
/// L'utilisateur peint des silhouettes de nuages au doigt ; le `Renderer` en
/// fait un volume de densité, éclairé selon le lieu/instant de la scène.
struct CanvasView: View {
    let context: SceneContext

    @State private var model = CanvasModel()
    @State private var cloudParameters = CloudParameters.neutral
    private let astro = SwiftAAAstroService()
    private let weather = OpenMeteoWeatherService()

    /// Direction du soleil résolue depuis l'`AstroService`, exprimée
    /// relativement au cap de la caméra (une photo prise vers le Sud place le
    /// soleil à l'opposé d'une photo prise vers le Nord).
    private var sunDirection: SIMD3<Float> {
        let position = astro.position(
            of: .sun, at: context.scene.coordinate, date: context.scene.date)
        let cameraRelative = CelestialPosition(
            body: .sun,
            azimuth: position.azimuth - context.scene.heading,
            altitude: position.altitude
        )
        return cameraRelative.worldDirection
    }

    /// tan(FOV/2) vertical : cale la projection du ciel sur le zoom de la photo.
    private var tanHalfFieldOfView: Float {
        Float(tan(context.scene.fieldOfView / 2))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                MetalView(
                    strokes: model.strokes,
                    sunDirection: sunDirection,
                    cloudParameters: cloudParameters,
                    cameraTanHalfFov: tanHalfFieldOfView,
                    landscape: context.landscape,
                    depthMap: context.depthMap,
                    contentID: context.id
                )
                .contentShape(Rectangle())
                .gesture(paintGesture(in: geometry.size))

                if !model.strokes.isEmpty {
                    clearButton
                        .padding(.bottom, 32)
                }
            }
        }
        .ignoresSafeArea()
        .task(id: context.id) { await loadWeather() }
    }

    /// Récupère la météo réelle pour la scène ; en cas d'échec, on conserve des
    /// paramètres neutres.
    private func loadWeather() async {
        do {
            let snapshot = try await weather.snapshot(
                at: context.scene.coordinate, date: context.scene.date)
            cloudParameters = CloudParameters(weather: snapshot)
        } catch {
            cloudParameters = .neutral
        }
    }

    private func paintGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = SIMD2(
                    Float(value.location.x / size.width),
                    Float(value.location.y / size.height)
                ).clamped()
                if model.isDrawing {
                    model.extendStroke(to: point)
                } else {
                    model.beginStroke(at: point)
                }
            }
            .onEnded { _ in model.endStroke() }
    }

    private var clearButton: some View {
        Button {
            model.clear()
        } label: {
            // Table « Aether » : le catalogue est `Aether.xcstrings`, pas le
            // `Localizable` par défaut.
            Text("action.clear", tableName: "Aether")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private extension SIMD2<Float> {
    /// Confine le point au canvas [0,1]² (un drag peut sortir des bords).
    func clamped() -> SIMD2<Float> {
        SIMD2(min(max(x, 0), 1), min(max(y, 0), 1))
    }
}
