import Foundation
import SwiftUI
import simd

/// Hôte du canvas de rendu volumétrique, pour un paysage donné. La photo est
/// affichée à son propre aspect (lettrage) pour éviter toute déformation ; les
/// paysages curés abstraits occupent le plein cadre. L'utilisateur peint des
/// silhouettes de nuages, éclairées selon le lieu/instant/cadrage de la scène.
struct CanvasView: View {
    let context: SceneContext

    @State private var model = CanvasModel()
    @State private var cloudParameters = CloudParameters.neutral
    private let astro = SwiftAAAstroService()
    private let weather = OpenMeteoWeatherService()

    /// Direction du soleil dans le repère caméra : cap (Nord vs Sud) + tangage.
    private var sunDirection: SIMD3<Float> {
        astro.position(of: .sun, at: context.scene.coordinate, date: context.scene.date)
            .cameraDirection(heading: context.scene.heading, pitch: context.scene.pitch)
    }

    /// tan(FOV/2) vertical : cale la projection du ciel sur le zoom de la photo.
    private var tanHalfFieldOfView: Float {
        Float(tan(context.scene.fieldOfView / 2))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            canvas
            if !model.strokes.isEmpty {
                VStack {
                    Spacer()
                    clearButton.padding(.bottom, 32)
                }
            }
        }
        .task(id: context.id) { await loadWeather() }
    }

    @ViewBuilder
    private var canvas: some View {
        let metalView = MetalView(
            strokes: model.strokes,
            sunDirection: sunDirection,
            cloudParameters: cloudParameters,
            cameraTanHalfFov: tanHalfFieldOfView,
            landscape: context.landscape,
            depthMap: context.depthMap,
            contentID: context.id
        )
        .overlay {
            // GeometryReader interne : taille réelle du rendu (cadre lettré ou
            // plein écran) pour normaliser les coordonnées du pinceau.
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(paintGesture(in: geometry.size))
            }
        }

        if let aspect = context.displayAspect {
            metalView.aspectRatio(aspect, contentMode: .fit)
        } else {
            metalView.ignoresSafeArea()
        }
    }

    /// Récupère la météo réelle pour la scène ; en cas d'échec, paramètres neutres.
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
