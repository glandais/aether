import Foundation
import SwiftUI
import simd

/// Hôte du canvas de rendu volumétrique, pour un paysage donné. La photo est
/// affichée à son propre aspect (lettrage) ; les paysages curés abstraits
/// occupent le plein cadre. L'utilisateur peint des silhouettes de nuages,
/// éclairées selon le lieu/cadrage de la scène et l'heure choisie (le curseur
/// déplace le soleil et la lune ; le nuage se rallume en conséquence).
struct CanvasView: View {
    let context: SceneContext

    @State private var model = CanvasModel()
    /// Heure locale choisie (heures, 0…24). `nil` = heure d'origine de la scène.
    @State private var hourOverride: Double?
    @State private var showBrushControls = false
    /// Orientation du regard au début d'un drag de rotation (lacet, tangage).
    @State private var rotationAnchor: SIMD2<Float>?
    /// Champ de vision choisi (radians). `nil` = FOV d'origine de la scène.
    @State private var fovOverride: Double?
    /// FOV au début d'un pincement, et garde anti-trait pendant le zoom.
    @State private var fovAnchor: Double?
    @State private var isZooming = false

    /// Plage de FOV au pincement (≈25°…100°).
    private static let minFieldOfView = 0.44
    private static let maxFieldOfView = 1.75

    private let astro = SwiftAAAstroService()
    private let atmosphere = Atmosphere.earth

    // Échelles ramenant la radiance atmosphérique dans la plage de travail du
    // nuage (réglées par capture). La couleur/teinte vient de l'atmosphère ; ces
    // facteurs ne font que caler la luminosité.
    private static let cloudSunStrength: Float = 12
    private static let cloudAmbientStrength: Float = 1.2
    /// Désaturation de l'ambiance bleue du ciel (0 = gris, 1 = bleu ciel pur),
    /// pour éviter que le corps du nuage ne vire au gris-bleu.
    private static let ambientSaturation: Float = 0.5

    /// Éclairage résolu pour l'instant courant : direction, couleur, ambiance.
    private struct ResolvedLight {
        var direction: SIMD3<Float>
        /// Direction monde du soleil (pour le ciel ; le ciel reste sombre la nuit
        /// quand le soleil est sous l'horizon, là où `direction` suit la lune).
        var skySunDirection: SIMD3<Float>
        var color: SIMD3<Float>
        var ambient: SIMD3<Float>
        /// Éclairement du sol (0 nuit → 1 jour) : assombrit le paysage la nuit.
        var groundLight: Float
        var isDaytime: Bool
    }

    var body: some View {
        let light = resolvedLight
        return ZStack {
            Color.black.ignoresSafeArea()
            canvas(light: light)
            VStack(spacing: 14) {
                Spacer()
                if model.canUndo || model.canRedo || !model.strokes.isEmpty {
                    editToolbar
                }
                timeBar(isDaytime: light.isDaytime)
            }
            .padding(.bottom, 28)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                rotateButton
                brushControls
            }
            .padding(.trailing, 16).padding(.top, 8)
        }
    }

    /// Bascule le mode rotation du regard (jumeau du bouton pinceau).
    private var rotateButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.isRotating.toggle() }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.headline)
                .foregroundStyle(model.isRotating ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "mode.lookAround", table: "Aether")))
    }

    // MARK: - Heure & éclairage

    private var sceneTimeZone: TimeZone {
        TimeZone(secondsFromGMT: Int(context.scene.utcOffset)) ?? .gmt
    }

    /// Heure locale d'origine de la scène (heures décimales).
    private var initialHour: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sceneTimeZone
        let components = calendar.dateComponents([.hour, .minute], from: context.scene.date)
        return Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60.0
    }

    private var currentHour: Double { hourOverride ?? initialHour }

    /// Instant effectif = jour de la scène, à l'heure locale choisie.
    private var effectiveDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sceneTimeZone
        let startOfDay = calendar.startOfDay(for: context.scene.date)
        return startOfDay.addingTimeInterval(currentHour * 3600)
    }

    /// Soleil le jour, lune la nuit (fondu au crépuscule), calé sur l'exposition.
    private var resolvedLight: ResolvedLight {
        let date = effectiveDate
        let coordinate = context.scene.coordinate
        let sun = astro.position(of: .sun, at: coordinate, date: date)
        let moon = astro.position(of: .moon, at: coordinate, date: date)
        let illumination = astro.moonIlluminatedFraction(date: date)

        // 1 quand le soleil est levé, 0 la nuit ; fondu dans la bande crépusculaire.
        let sunWeight = SkyLighting.smoothstep(-0.08, 0.06, Float(sun.altitude))
        let moonLight = MoonLighting(moonAltitude: moon.altitude, illuminatedFraction: illumination)

        // Le regard de l'utilisateur (lacet + tangage) s'ajoute à l'attitude de
        // la scène : le soleil/la lune tournent dans le repère caméra comme le
        // ciel (cohérence via la base partagée, cf. `CameraPose`).
        let gazeHeading = context.scene.heading + Double(model.viewYaw)
        let gazePitch = context.scene.pitch + Double(model.viewPitch)
        let sunDir = sun.cameraDirection(
            heading: gazeHeading, pitch: gazePitch, roll: context.scene.roll)
        let moonDir = moon.cameraDirection(
            heading: gazeHeading, pitch: gazePitch, roll: context.scene.roll)
        var direction = moonDir + (sunDir - moonDir) * sunWeight
        // Soleil et lune opposés : le mélange peut s'annuler → repli sur le dominant.
        direction = length(direction) < 0.01 ? (sunWeight >= 0.5 ? sunDir : moonDir) : normalize(direction)

        // Éclairage du nuage dérivé de la **même** atmosphère que le ciel :
        // soleil = transmittance solaire (chaud bas, blanc haut, nul la nuit) ;
        // ambiance = radiance du ciel au zénith (bleue le jour), désaturée pour
        // garder un nuage clair plutôt que gris-bleu.
        let sunWorld = sun.worldDirection
        let sunDayColor = atmosphere.sunTransmittance(sunDirection: sunWorld) * Self.cloudSunStrength
        let zenith = atmosphere.skyRadiance(viewDirection: SIMD3(0, 1, 0), sunDirection: sunWorld)
        let zenithLuma = 0.2126 * zenith.x + 0.7152 * zenith.y + 0.0722 * zenith.z
        let ambientDayColor =
            (SIMD3(repeating: zenithLuma) + (zenith - SIMD3(repeating: zenithLuma)) * Self.ambientSaturation)
            * Self.cloudAmbientStrength

        let exposure = context.skyExposure
        let color = (sunDayColor * sunWeight + moonLight.color * (1 - sunWeight)) * exposure
        let ambient = (ambientDayColor * sunWeight + moonLight.ambient * (1 - sunWeight)) * exposure

        // Sol éclairé par le jour, avec un plancher lunaire (pas de bande claire
        // sous un ciel noir de minuit).
        let moonLuma = 0.2126 * moonLight.color.x + 0.7152 * moonLight.color.y + 0.0722 * moonLight.color.z
        let groundLight = max(sunWeight, min(moonLuma * 0.06, 0.15), 0.02)

        return ResolvedLight(
            direction: direction, skySunDirection: sun.worldDirection,
            color: color, ambient: ambient, groundLight: groundLight, isDaytime: sunWeight >= 0.5)
    }

    /// FOV effectif : valeur pincée si présente, sinon celui de la scène.
    private var effectiveFieldOfView: Double {
        fovOverride ?? context.scene.fieldOfView
    }

    private var tanHalfFieldOfView: Float {
        Float(tan(effectiveFieldOfView / 2))
    }

    /// Base caméra → monde du regard (attitude de la scène + rotation utilisateur).
    private var cameraPose: CameraPose {
        CameraPose(
            heading: context.scene.heading + Double(model.viewYaw),
            pitch: context.scene.pitch + Double(model.viewPitch))
    }

    // MARK: - Vues

    @ViewBuilder
    private func canvas(light: ResolvedLight) -> some View {
        let basis = cameraPose.basis
        let metalView = MetalView(
            strokes: model.strokes,
            sunDirection: light.direction,
            skySunDirection: light.skySunDirection,
            atmosphere: atmosphere,
            groundLight: light.groundLight,
            sunColor: light.color,
            skyAmbient: light.ambient,
            cloudParameters: context.cloudParameters,
            cameraTanHalfFov: tanHalfFieldOfView,
            cameraRight: basis.right,
            cameraUp: basis.up,
            cameraForward: basis.forward,
            landscape: context.landscape,
            contentID: context.id
        )
        .overlay {
            // GeometryReader interne : taille réelle du rendu (cadre lettré ou
            // plein écran) pour normaliser les coordonnées du pinceau.
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(paintGesture(in: geometry.size))
                    .simultaneousGesture(zoomGesture)
            }
        }

        if let aspect = context.displayAspect {
            metalView.aspectRatio(aspect, contentMode: .fit)
        } else {
            metalView.ignoresSafeArea()
        }
    }

    /// Curseur d'heure : déplace le soleil/la lune, le nuage se rallume.
    private func timeBar(isDaytime: Bool) -> some View {
        let hour = Binding(
            get: { currentHour },
            set: { hourOverride = $0 }
        )
        return HStack(spacing: 12) {
            Image(systemName: isDaytime ? "sun.max" : "moon.stars")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Slider(value: hour, in: 0...24)
                .tint(.white.opacity(0.55))
            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 24)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sceneTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: effectiveDate)
    }

    /// Réglages du pinceau (rayon, adoucissement), révélés par un bouton sobre.
    /// Affectent les prochains traits peints.
    private var brushControls: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showBrushControls.toggle() }
            } label: {
                Image(systemName: "paintbrush.pointed")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            if showBrushControls {
                VStack(spacing: 14) {
                    brushSlider(
                        icon: "smallcircle.filled.circle",
                        value: binding(\.brushRadius), range: 0.03...0.25)
                    brushSlider(
                        icon: "drop",
                        value: binding(\.brushSoftness), range: 0...1)
                }
                .frame(width: 180)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
            }
        }
    }

    private func brushSlider(icon: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: value, in: range).tint(.white.opacity(0.55))
        }
    }

    /// Binding vers une propriété du `CanvasModel` (@Observable via @State).
    private func binding(_ keyPath: ReferenceWritableKeyPath<CanvasModel, Float>) -> Binding<Float> {
        Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
    }

    /// Barre d'édition : annuler / rétablir / effacer (registre sobre).
    private var editToolbar: some View {
        HStack(spacing: 24) {
            editButton("arrow.uturn.backward", "action.undo", enabled: model.canUndo) { model.undo() }
            editButton("arrow.uturn.forward", "action.redo", enabled: model.canRedo) { model.redo() }
            editButton("trash", "action.clear", enabled: !model.strokes.isEmpty) { model.clear() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func editButton(
        _ systemName: String, _ labelKey: String.LocalizationValue,
        enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .accessibilityLabel(Text(String(localized: labelKey, table: "Aether")))
    }

    // MARK: - Météo

    /// Sensibilité de la rotation : un drag plein écran couvre ~`yawSpan` en
    /// lacet et ~`pitchSpan` en tangage (à caler par capture).
    private static let yawSpan: Float = 2.0
    private static let pitchSpan: Float = 1.6

    private func paintGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if isZooming { return }  // un pincement est en cours : pas de trait
                if model.isRotating {
                    rotate(value, in: size)
                } else {
                    paint(value, in: size)
                }
            }
            .onEnded { _ in
                if model.isRotating {
                    rotationAnchor = nil
                } else {
                    model.endStroke()
                }
            }
    }

    /// Pincement à deux doigts → champ de vision (zoom). Disponible **seulement
    /// en mode rotation** (le pincement est un mouvement de caméra, comme le
    /// drag qui pivote le regard). Pincer pour écarter (magnification > 1)
    /// rétrécit le FOV (zoom avant) ; il efface les nuages à la prise (on
    /// reframe un ciel vierge). Clampé entre min/max FOV.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard model.isRotating else { return }
                if fovAnchor == nil {
                    fovAnchor = effectiveFieldOfView
                    isZooming = true
                    model.clearForCameraChange()
                }
                let target = (fovAnchor ?? effectiveFieldOfView) / Double(value.magnification)
                fovOverride = min(max(target, Self.minFieldOfView), Self.maxFieldOfView)
            }
            .onEnded { _ in
                fovAnchor = nil
                isZooming = false
            }
    }

    /// Peinture d'un trait (coordonnées normalisées au canvas).
    private func paint(_ value: DragGesture.Value, in size: CGSize) {
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

    /// Rotation du regard. « Saisir le ciel » : drag à droite → le ciel glisse
    /// à droite (on tourne la tête à gauche) ; drag vers le bas → on lève les
    /// yeux. Les nuages s'effacent à la prise (on pivote un ciel vierge).
    private func rotate(_ value: DragGesture.Value, in size: CGSize) {
        let anchor: SIMD2<Float>
        if let existing = rotationAnchor {
            anchor = existing
        } else {
            anchor = SIMD2(model.viewYaw, model.viewPitch)
            rotationAnchor = anchor
            model.clearForCameraChange()
        }
        let yaw = anchor.x - Float(value.translation.width / size.width) * Self.yawSpan
        let pitch = anchor.y + Float(value.translation.height / size.height) * Self.pitchSpan
        model.setRotation(yaw: yaw, pitch: pitch)
    }
}

private extension SIMD2<Float> {
    /// Confine le point au canvas [0,1]² (un drag peut sortir des bords).
    func clamped() -> SIMD2<Float> {
        SIMD2(min(max(x, 0), 1), min(max(y, 0), 1))
    }
}
