import Foundation
import SwiftUI
import simd

/// Hôte plein écran du canvas de rendu volumétrique. L'utilisateur peint des
/// silhouettes de nuages au doigt ; le `Renderer` en fait un volume de densité.
struct CanvasView: View {
    @State private var model = CanvasModel()

    /// Scène par défaut : Paris au crépuscule (heure UTC). Le choix du lieu et
    /// de l'heure passera par les réglages (étape future).
    private static let defaultScene = Scene(
        title: "Paris",
        coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522),
        date: makeDefaultDate()
    )
    private let astro = SwiftAAAstroService()

    /// Direction du soleil résolue depuis l'`AstroService` pour la scène.
    private var sunDirection: SIMD3<Float> {
        astro.position(of: .sun, at: Self.defaultScene.coordinate, date: Self.defaultScene.date)
            .worldDirection
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                MetalView(strokes: model.strokes, sunDirection: sunDirection)
                    .contentShape(Rectangle())
                    .gesture(paintGesture(in: geometry.size))

                if !model.strokes.isEmpty {
                    clearButton
                        .padding(.bottom, 32)
                }
            }
        }
        .ignoresSafeArea()
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

private extension CanvasView {
    static func makeDefaultDate() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 25
        components.hour = 19
        components.minute = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? Date()
    }
}

private extension SIMD2<Float> {
    /// Confine le point au canvas [0,1]² (un drag peut sortir des bords).
    func clamped() -> SIMD2<Float> {
        SIMD2(min(max(x, 0), 1), min(max(y, 0), 1))
    }
}
