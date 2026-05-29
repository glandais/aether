import Foundation
import SwiftUI
import simd

/// Hôte du canvas de rendu volumétrique, pour un paysage donné. La photo est
/// affichée à son propre aspect (lettrage) ; les paysages curés abstraits
/// occupent le plein cadre. L'utilisateur peint des silhouettes de nuages,
/// éclairées selon le lieu/cadrage de la scène et l'heure choisie (le curseur
/// déplace le soleil et la lune ; le nuage se rallume en conséquence).
/// Sens du défilement automatique du temps (exclusif : un seul actif).
private enum AutoPlay {
    case none, forward, backward

    /// Signe du sens (`0` si inactif) ; la vitesse est portée à part.
    var direction: Double {
        switch self {
        case .none: 0
        case .forward: 1
        case .backward: -1
        }
    }
}

/// Panneau d'outil ouvert. Exclusif : un seul à la fois, pour ne pas encombrer
/// le ciel ni déborder en paysage. `more` regroupe les réglages contextuels
/// (ciel, lieu) sous un seul bouton, façon « More » HIG.
private enum ToolPanel {
    case brush, more
}

struct CanvasView: View {
    let context: SceneContext

    @State private var model = CanvasModel()
    /// Heure locale choisie (heures, 0…24). `nil` = heure d'origine de la scène.
    @State private var hourOverride: Double?
    /// Jour choisi. `nil` = date d'origine de la scène. Déplace soleil, lune et
    /// étoiles (saison, phase lunaire) sans toucher au cadrage.
    @State private var dateOverride: Date?
    /// Lieu choisi. `nil` = lieu d'origine de la scène. Repositionne soleil,
    /// lune et étoiles (et, via `timeZoneOverride`, le fuseau de l'heure locale).
    @State private var coordinateOverride: GeoCoordinate?
    /// Fuseau résolu (tzf) pour le lieu choisi. `nil` = fuseau d'origine.
    @State private var timeZoneOverride: TimeZone?
    @State private var showLocationPicker = false
    /// Feuille d'éphéméride (lever/coucher, phase) ouverte.
    @State private var showEphemeris = false
    /// Résolution « ici & maintenant » en cours (position GPS + fuseau).
    @State private var isResolvingHereNow = false
    /// Défilement automatique du temps (aucun / avance / recul). Exclusif.
    @State private var autoPlay: AutoPlay = .none
    /// Multiplicateur de vitesse du défilement (1, 2, 4, 8, 16). 1× = 0,25 h/s.
    @State private var autoPlaySpeed = 1
    /// Panneau d'outil ouvert (pinceau, ou « More » = ciel + lieu). Exclusif :
    /// ouvrir l'un referme l'autre. Rendu en carte flottante **à côté** des
    /// pastilles (pas d'expansion inline qui repousserait la colonne).
    @State private var activePanel: ToolPanel?
    /// Révèle toutes les options (retour, regard, pinceau, heure). Replié par
    /// défaut : seule la bascule « Options » est visible, pour un ciel dégagé.
    @State private var showOptions = false
    /// Hauteur compacte (paysage iPhone) : la palette passe en rangée
    /// horizontale, la largeur (abondante) absorbant les pastilles.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Orientation du regard au début d'un drag de rotation (lacet, tangage).
    @State private var rotationAnchor: SIMD2<Float>?
    /// Champ de vision choisi (radians). `nil` = FOV d'origine de la scène.
    @State private var fovOverride: Double?
    /// FOV au début d'un pincement, et garde anti-trait pendant le zoom.
    @State private var fovAnchor: Double?
    @State private var isZooming = false
    /// Étoiles visibles résolues pour le lieu/heure courant, et leur révision.
    /// Recalculées seulement quand `starKey` change (cf. `.task`), jamais par
    /// frame de rotation/zoom.
    @State private var starField: [VisibleStar] = []
    @State private var starRevision = 0

    /// Catalogue BSC5 chargé une seule fois (paresseux, partagé).
    private static let starCatalog: [Star] = StarCatalog.load()

    /// Plage de FOV au pincement (≈25°…100°).
    private static let minFieldOfView = 0.44
    private static let maxFieldOfView = 1.75

    /// Vitesse de base du défilement automatique (heures par seconde réelle) au
    /// multiplicateur 1×, et multiplicateurs disponibles (cycliques).
    private static let baseHoursPerSecond = 0.25
    private static let autoPlaySpeeds = [1, 2, 4, 8, 16]

    private let astro = SwiftAAAstroService()
    private let atmosphere = Atmosphere.earth
    private let timeZoneService = TzfTimeZoneService()
    private let locationService = CoreLocationService()

    // Échelles ramenant la radiance atmosphérique dans la plage de travail du
    // nuage (réglées par capture). La couleur/teinte vient de l'atmosphère ; ces
    // facteurs ne font que caler la luminosité.
    private static let cloudSunStrength: Float = 12
    private static let cloudAmbientStrength: Float = 1.2
    /// Désaturation de l'ambiance bleue du ciel (0 = gris, 1 = bleu ciel pur),
    /// pour éviter que le corps du nuage ne vire au gris-bleu.
    private static let ambientSaturation: Float = 0.5
    /// Luminosités des disques solaire/lunaire dessinés dans le ciel (réglées par
    /// capture). Le soleil sature vers le blanc ; la lune reste tamisée.
    private static let sunDiscBrightness: Float = 1.3
    private static let moonDiscBrightness: Float = 0.9
    /// Blanc froid du disque lunaire (la phase/teinte vient de la géométrie).
    private static let moonDiscTint = SIMD3<Float>(0.85, 0.88, 1.0)

    /// Éclairage résolu pour l'instant courant : direction, couleur, ambiance.
    private struct ResolvedLight {
        var direction: SIMD3<Float>
        /// Direction monde du soleil (pour le ciel ; le ciel reste sombre la nuit
        /// quand le soleil est sous l'horizon, là où `direction` suit la lune).
        var skySunDirection: SIMD3<Float>
        /// Couleurs des disques solaire/lunaire dessinés dans le ciel (la position
        /// de la lune réutilise `moonSkyDirection`).
        var sunDiscColor: SIMD3<Float>
        var moonDiscColor: SIMD3<Float>
        var color: SIMD3<Float>
        var ambient: SIMD3<Float>
        /// Éclairement du sol (0 nuit → 1 jour) : assombrit le paysage la nuit.
        var groundLight: Float
        var isDaytime: Bool
        /// Direction monde de la lune (pour le reflet/glint sur la mer la nuit).
        var moonSkyDirection: SIMD3<Float>
        /// Couleur du clair de lune (intensité comprise), pour le glint marin.
        var moonGlint: SIMD3<Float>
        /// Poids nocturne (0 jour → 1 nuit) : ouvre les contributions lunaires.
        var nightWeight: Float
        /// Radiance du ciel au zénith et à l'horizon (intégrales CPU), pour le
        /// reflet bon marché de la mer (dégradé, sans intégrale par pixel).
        var skyZenithRadiance: SIMD3<Float>
        var skyHorizonRadiance: SIMD3<Float>
        /// Positions horizontales du Soleil et de la Lune (pour centrer le regard
        /// et l'éphéméride). Réutilisées telles quelles, sans recalcul.
        var sunPosition: CelestialPosition
        var moonPosition: CelestialPosition
    }

    var body: some View {
        let light = resolvedLight
        return ZStack {
            Color.black.ignoresSafeArea()
            canvas(light: light)
            if showOptions {
                VStack(spacing: 14) {
                    Spacer()
                    timeBar(isDaytime: light.isDaytime)
                }
                .padding(.bottom, 28)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .overlay(alignment: .topTrailing) {
            toolPalette(light: light)
                .padding(.trailing, 16).padding(.top, 8)
        }
        // Recalcul des étoiles hors `body` : seulement au changement de lieu/heure
        // (bucket ~60 s), pas à chaque frame de rotation/zoom.
        .task(id: starKey) { recomputeStars() }
        // Défilement automatique : avance/recule l'heure en continu (≈30 ips) au
        // rythme d'une heure par seconde réelle. `ContinuousClock` mesure le dt
        // réel (lissage indépendant de la cadence) ; relancé/arrêté au changement
        // d'état via `id:`.
        .task(id: autoPlay) {
            guard autoPlay != .none else { return }
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                if Task.isCancelled { break }
                let now = clock.now
                let elapsed = last.duration(to: now)
                last = now
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) * 1e-18
                // Plafond : après une longue suspension (app en arrière-plan), on
                // ne saute pas brutalement dans le temps.
                let seconds = min(max(elapsedSeconds, 0), 0.5)
                // Débit lu en direct : un changement de vitesse pendant le
                // défilement s'applique sans relancer la boucle.
                let rate = autoPlay.direction * Self.baseHoursPerSecond * Double(autoPlaySpeed)
                advanceTime(byHours: rate * seconds)
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerView(
                initial: effectiveCoordinate, locationService: locationService
            ) { coordinate in
                coordinateOverride = coordinate
                // Coordonnée appliquée tout de suite (astro/étoiles) ; le fuseau
                // se corrige dès la résolution tzf (bref décalage du seul libellé
                // d'heure, sans incidence sur le ciel).
                Task { timeZoneOverride = await timeZoneService.timeZone(for: coordinate) }
            }
        }
        .sheet(isPresented: $showEphemeris) {
            EphemerisView(
                ephemeris: astro.ephemeris(at: effectiveCoordinate, date: effectiveDate),
                timeZone: effectiveTimeZone)
        }
    }

    /// Clé de recalcul des étoiles : lieu + tranche de temps (~60 s ; la rotation
    /// sidérale ~0,25°/min reste sous le pixel).
    private struct StarKey: Hashable {
        let latitude: Double
        let longitude: Double
        let timeBucket: Int
    }

    private var starKey: StarKey {
        StarKey(
            latitude: effectiveCoordinate.latitude,
            longitude: effectiveCoordinate.longitude,
            timeBucket: Int(effectiveDate.timeIntervalSince1970 / 60))
    }

    /// Résout les directions monde des étoiles visibles pour l'instant courant.
    private func recomputeStars() {
        let coordinate = effectiveCoordinate
        let sidereal = StarCatalog.localSiderealTime(
            date: effectiveDate, longitudeEast: coordinate.longitude)
        starField = StarCatalog.visibleStars(
            Self.starCatalog, latitude: coordinate.latitude, siderealTime: sidereal)
        starRevision += 1
    }

    /// Bascule unique « Options » : repliée par défaut pour garder le ciel
    /// dégagé, elle révèle d'un geste l'ensemble des réglages (retour, regard,
    /// pinceau, heure).
    private var optionsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showOptions.toggle()
                if !showOptions { activePanel = nil }  // replier referme tout panneau
            }
        } label: {
            bubbleLabel("slider.horizontal.3", active: showOptions)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "mode.options", table: "Aether")))
    }

    /// Palette d'outils, axe adaptatif : colonne en portrait, rangée en paysage
    /// (hauteur compacte). La bascule « Options » est toujours visible ; ouverte,
    /// elle révèle regard, édition (annuler/rétablir/effacer), pinceau et
    /// « More » (ciel + lieu). Le panneau
    /// actif flotte **à côté** des pastilles (carte `ultraThinMaterial`) sans
    /// jamais les repousser : à gauche de la colonne (portrait), sous la rangée
    /// (paysage). C'est ce découplage qui supprime le débordement en paysage.
    @ViewBuilder
    private func toolPalette(light: ResolvedLight) -> some View {
        let card = activePanelCard(light: light)
        if isCompactHeight {
            VStack(alignment: .trailing, spacing: 12) {
                bubbleStack
                card
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                card
                bubbleStack
            }
        }
    }

    /// La pile de pastilles (axe adaptatif), sans le panneau.
    @ViewBuilder
    private var bubbleStack: some View {
        let reveal = AnyTransition.opacity.combined(
            with: .move(edge: isCompactHeight ? .trailing : .top))
        let bubbles = Group {
            optionsButton
            if showOptions {
                rotateButton.transition(reveal)
                // Annuler / rétablir / effacer : pastilles principales directes
                // (pas de sous-menu), révélées seulement dès qu'il y a à éditer.
                if hasEdits {
                    actionBubble("arrow.uturn.backward", "action.undo", enabled: model.canUndo) { model.undo() }
                        .transition(reveal)
                    actionBubble("arrow.uturn.forward", "action.redo", enabled: model.canRedo) { model.redo() }
                        .transition(reveal)
                    actionBubble("trash", "action.clear", enabled: !model.strokes.isEmpty) { model.clear() }
                        .transition(reveal)
                }
                brushBubble.transition(reveal)
                moreBubble.transition(reveal)
            }
        }
        if isCompactHeight {
            HStack(alignment: .top, spacing: 10) { bubbles }
        } else {
            VStack(alignment: .trailing, spacing: 10) { bubbles }
        }
    }

    /// Carte du panneau actif (vide si aucun), en matériau translucide.
    @ViewBuilder
    private func activePanelCard(light: ResolvedLight) -> some View {
        if let panel = activePanel {
            panelContent(panel, light: light)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
        }
    }

    /// Paysage iPhone (la palette passe à l'horizontale).
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    /// Bascule le mode rotation du regard (jumeau du bouton pinceau).
    private var rotateButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.isRotating.toggle() }
        } label: {
            bubbleLabel("arrow.up.and.down.and.arrow.left.and.right", active: model.isRotating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "mode.lookAround", table: "Aether")))
    }

    // MARK: - Heure & éclairage

    /// Lieu effectif : choisi par l'utilisateur, sinon celui de la scène.
    private var effectiveCoordinate: GeoCoordinate {
        coordinateOverride ?? context.scene.coordinate
    }

    /// Fuseau effectif : résolu pour le lieu choisi (tzf), sinon celui de la scène.
    private var effectiveTimeZone: TimeZone { timeZoneOverride ?? context.scene.timeZone }

    /// Heure locale d'origine de la scène (heures décimales).
    private var initialHour: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = effectiveTimeZone
        let components = calendar.dateComponents([.hour, .minute], from: context.scene.date)
        return Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60.0
    }

    private var currentHour: Double { hourOverride ?? initialHour }

    /// Jour montré par le sélecteur : **midi UTC** du jour choisi (ou, à défaut,
    /// du jour local de la scène). Le sélecteur travaille en UTC sur cette valeur
    /// ancrée à midi : aucun risque de bascule de jour près de minuit, ni de
    /// désync calendrier/champ dû au fuseau fractionnaire de la scène.
    private var effectiveDay: Date { dateOverride ?? defaultDay }

    /// Jour local d'origine de la scène, ramené à midi UTC pour le sélecteur.
    private var defaultDay: Date {
        var sceneCalendar = Calendar(identifier: .gregorian)
        sceneCalendar.timeZone = effectiveTimeZone
        let day = sceneCalendar.dateComponents([.year, .month, .day], from: context.scene.date)
        return Self.noonUTC(day) ?? context.scene.date
    }

    /// Instant effectif = jour choisi (an/mois/jour lus en UTC) à l'heure locale
    /// choisie, placé dans le fuseau de la scène.
    private var effectiveDate: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let day = utc.dateComponents([.year, .month, .day], from: effectiveDay)
        var sceneCalendar = Calendar(identifier: .gregorian)
        sceneCalendar.timeZone = effectiveTimeZone
        var startComponents = DateComponents()
        startComponents.year = day.year
        startComponents.month = day.month
        startComponents.day = day.day
        let startOfDay = sceneCalendar.date(from: startComponents) ?? effectiveDay
        return startOfDay.addingTimeInterval(currentHour * 3600)
    }

    /// Midi UTC du jour donné (an/mois/jour), point d'ancrage stable du sélecteur.
    private static func noonUTC(_ day: DateComponents) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        var noon = DateComponents()
        noon.year = day.year
        noon.month = day.month
        noon.day = day.day
        noon.hour = 12
        return utc.date(from: noon)
    }

    /// Soleil le jour, lune la nuit (fondu au crépuscule), calé sur l'exposition.
    private var resolvedLight: ResolvedLight {
        let date = effectiveDate
        let coordinate = effectiveCoordinate
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
        // Radiance du ciel près de l'horizon, dans l'azimut du soleil (pour la
        // chaleur du reflet bas), avec repli vers le Nord si le soleil est haut.
        let sunHoriz = SIMD3<Float>(sunWorld.x, 0, sunWorld.z)
        let horizonDir = length(sunHoriz) > 0.05
            ? normalize(SIMD3<Float>(sunHoriz.x, 0.08, sunHoriz.z))
            : SIMD3<Float>(0, 0.08, -1)
        let horizonRadiance = atmosphere.skyRadiance(viewDirection: horizonDir, sunDirection: sunWorld)
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

        // Couleurs des disques. Le soleil réutilise la transmittance solaire
        // (chaude bas, blanche haut, nulle sous l'horizon → disque qui s'éteint
        // seul). La lune est un blanc froid atténué par son altitude ; la phase
        // (croissant/gibbeuse) est calculée côté shader, donc pas de produit par
        // la fraction éclairée ici.
        let sunDiscColor = atmosphere.sunTransmittance(sunDirection: sunWorld)
            * exposure * Self.sunDiscBrightness
        let moonAltitudeFade = SkyLighting.smoothstep(-0.02, 0.05, Float(moon.altitude))
        let moonDiscColor = Self.moonDiscTint * (moonAltitudeFade * Self.moonDiscBrightness)

        return ResolvedLight(
            direction: direction, skySunDirection: sun.worldDirection,
            sunDiscColor: sunDiscColor, moonDiscColor: moonDiscColor,
            color: color, ambient: ambient, groundLight: groundLight, isDaytime: sunWeight >= 0.5,
            moonSkyDirection: moon.worldDirection,
            moonGlint: moonLight.color * exposure,
            nightWeight: 1 - sunWeight,
            skyZenithRadiance: zenith,
            skyHorizonRadiance: horizonRadiance,
            sunPosition: sun,
            moonPosition: moon)
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
            sunDiscColor: light.sunDiscColor,
            moonDiscColor: light.moonDiscColor,
            atmosphere: atmosphere,
            groundLight: light.groundLight,
            sunColor: light.color,
            skyAmbient: light.ambient,
            cloudParameters: context.cloudParameters,
            sea: context.sea,
            moonSkyDirection: light.moonSkyDirection,
            moonGlint: light.moonGlint,
            nightWeight: light.nightWeight,
            skyZenithRadiance: light.skyZenithRadiance,
            skyHorizonRadiance: light.skyHorizonRadiance,
            stars: starField,
            starRevision: starRevision,
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

    /// Sous-menu « lieu » : coordonnée courante, ouverture de la carte, date du
    /// jour (saison, phase lunaire, ciel étoilé), et « ici & maintenant » (recale
    /// lieu, jour et heure sur l'instant courant).
    private var positionPanel: some View {
        let day = Binding(
            get: { effectiveDay },
            set: { dateOverride = $0 }
        )
        return VStack(alignment: .trailing, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DatePicker("", selection: day, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.timeZone, .gmt)
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                    .accessibilityLabel(Text(String(localized: "time.date", table: "Aether")))
            }

            Text(locationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 22) {
                editButton("map", "location.title", enabled: true) {
                    activePanel = nil; showLocationPicker = true
                }
                Button { activePanel = nil; resetToHereAndNow() } label: {
                    Group {
                        if isResolvingHereNow {
                            ProgressView()
                        } else {
                            Image(systemName: "scope").font(.body)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .disabled(isResolvingHereNow)
                .accessibilityLabel(Text(String(localized: "location.hereNow", table: "Aether")))
            }
        }
    }

    /// Recale lieu (position GPS), jour et heure sur l'instant courant. Échec
    /// silencieux si la position est indisponible (refus, pas de fix).
    private func resetToHereAndNow() {
        isResolvingHereNow = true
        Task {
            defer { isResolvingHereNow = false }
            guard let coordinate = try? await locationService.currentCoordinate() else { return }
            let zone = await timeZoneService.timeZone(for: coordinate)
            coordinateOverride = coordinate
            timeZoneOverride = zone
            // Instant courant dans le fuseau résolu, exprimé comme les sélecteurs :
            // jour ancré à midi UTC, heure locale décimale.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone ?? .current
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: Date())
            dateOverride = Self.noonUTC(components)
            hourOverride = Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60
        }
    }

    /// Coordonnée effective compacte, ex. « 48.9°N, 2.4°E ».
    private var locationLabel: String {
        let coordinate = effectiveCoordinate
        let lat = String(
            format: "%.1f°%@", abs(coordinate.latitude), coordinate.latitude >= 0 ? "N" : "S")
        let lon = String(
            format: "%.1f°%@", abs(coordinate.longitude), coordinate.longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }

    /// Curseur d'heure, encadré par deux bascules de défilement automatique
    /// (recul / avance, mutuellement exclusives) : déplace le soleil/la lune, le
    /// nuage se rallume.
    private func timeBar(isDaytime: Bool) -> some View {
        let hour = Binding(
            get: { currentHour },
            set: { hourOverride = $0 }
        )
        return HStack(spacing: 12) {
            Image(systemName: isDaytime ? "sun.max" : "moon.stars")
                .font(.footnote)
                .foregroundStyle(.secondary)
            autoPlayButton(.backward, icon: "backward.fill", label: "time.rewind")
            Slider(value: hour, in: 0...24)
                .tint(.white.opacity(0.55))
            autoPlayButton(.forward, icon: "forward.fill", label: "time.advance")
            speedButton
            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        // Cape la largeur : en paysage le curseur resterait sinon collé aux bords.
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
    }

    /// Bascule de défilement automatique (recul ou avance). Réactiver le même
    /// sens l'arrête ; activer l'autre bascule de sens (exclusion mutuelle).
    private func autoPlayButton(
        _ mode: AutoPlay, icon: String, label: String.LocalizationValue
    ) -> some View {
        Button {
            autoPlay = (autoPlay == mode) ? .none : mode
        } label: {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(autoPlay == mode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: label, table: "Aether")))
    }

    /// Règle la vitesse de défilement : cycle 1× → 2× → 4× → 8× → 16× → 1×.
    private var speedButton: some View {
        Button {
            let speeds = Self.autoPlaySpeeds
            let index = speeds.firstIndex(of: autoPlaySpeed) ?? 0
            autoPlaySpeed = speeds[(index + 1) % speeds.count]
        } label: {
            Text(verbatim: "\(autoPlaySpeed)×")
                .font(.caption.monospacedDigit())
                .foregroundStyle(autoPlay == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 30, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "time.speed", table: "Aether")))
        .accessibilityValue(Text(verbatim: "\(autoPlaySpeed)×"))
    }

    /// Avance (signe positif) ou recule l'heure courante de `hours`, en
    /// franchissant minuit : tout multiple de 24 h décale le jour d'autant (le
    /// jour est ancré à midi UTC, comme le sélecteur). Robuste à un `hours` > 24
    /// (réveil après une longue veille).
    private func advanceTime(byHours hours: Double) {
        let baseDay = effectiveDay
        let raw = currentHour + hours
        let dayShift = (raw / 24).rounded(.down)
        hourOverride = raw - dayShift * 24  // ramené dans [0, 24)
        if dayShift != 0 {
            dateOverride = baseDay.addingTimeInterval(dayShift * 86_400)
        }
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = effectiveTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: effectiveDate)
    }

    /// Y a-t-il quelque chose à éditer (trait en cours ou historique) ? Conditionne
    /// l'apparition du sous-menu d'édition.
    private var hasEdits: Bool {
        model.canUndo || model.canRedo || !model.strokes.isEmpty
    }

    /// Bouton-bascule façon pinceau : révèle un panneau aligné à droite,
    /// `.ultraThinMaterial`, sous un bouton circulaire (teinté quand ouvert).
    /// Pastille circulaire de taille **uniforme** quelle que soit la largeur du
    /// symbole (sinon les cercles diffèrent et s'alignent mal). Teintée si active.
    private func bubbleLabel(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .padding(13)
            .background(.ultraThinMaterial, in: Circle())
    }

    /// Pastille-bascule exclusive : ouvrir un panneau referme l'autre. Le
    /// contenu est rendu à part par `panelContent` (carte flottante).
    private func bubbleToggle(
        _ panel: ToolPanel, icon: String, label: String.LocalizationValue
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                activePanel = (activePanel == panel) ? nil : panel
            }
        } label: {
            bubbleLabel(icon, active: activePanel == panel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: label, table: "Aether")))
    }

    /// Pastille-action principale (annuler/rétablir/effacer) : déclenche une
    /// action sans panneau, grisée quand indisponible. Même pastille circulaire
    /// que les bascules, pour un alignement homogène dans la palette.
    private func actionBubble(
        _ icon: String, _ label: String.LocalizationValue,
        enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
                .padding(13)
                .background(.ultraThinMaterial, in: Circle())
                // Pastille entière atténuée quand indisponible : un glyphe
                // tertiaire seul serait illisible sur l'horizon clair.
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(String(localized: label, table: "Aether")))
    }

    private var brushBubble: some View {
        bubbleToggle(.brush, icon: "paintbrush.pointed", label: "group.brush")
    }

    /// Pastille « More » : regroupe les réglages contextuels (ciel, lieu).
    private var moreBubble: some View {
        bubbleToggle(.more, icon: "ellipsis", label: "group.more")
    }

    /// Contenu du panneau actif.
    @ViewBuilder
    private func panelContent(_ panel: ToolPanel, light: ResolvedLight) -> some View {
        switch panel {
        case .brush:
            VStack(spacing: 14) {
                brushSlider(
                    icon: "smallcircle.filled.circle",
                    value: binding(\.brushRadius), range: 0.03...0.25)
                brushSlider(
                    icon: "drop",
                    value: binding(\.brushSoftness), range: 0...1)
            }
            .frame(width: 180)
        case .more:
            // Réglages contextuels (rares par geste) : ciel (centrer soleil/lune,
            // éphéméride) et lieu. Les actions qui ouvrent une feuille (carte,
            // éphéméride) ou recadrent le regard referment d'abord le panneau.
            VStack(alignment: .trailing, spacing: 16) {
                HStack(spacing: 22) {
                    editButton("sun.max", "sky.centerSun", enabled: light.sunPosition.altitude > 0) {
                        activePanel = nil; center(on: light.sunPosition)
                    }
                    editButton("moon.stars", "sky.centerMoon", enabled: light.moonPosition.altitude > 0) {
                        activePanel = nil; center(on: light.moonPosition)
                    }
                    editButton("info.circle", "ephemeris.title", enabled: true) {
                        activePanel = nil; showEphemeris = true
                    }
                }
                Divider()
                positionPanel
            }
            // Borne la largeur : sinon le Divider étire la carte sur toute la
            // largeur proposée (grand vide à gauche, surtout en paysage).
            .frame(width: 230)
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

    /// Oriente le regard vers un astre : le cap/tangage de visée rejoignent son
    /// azimut/altitude (le tangage est clampé par `CanvasModel`). Comme toute
    /// reframe, on repart d'un ciel vierge.
    private func center(on body: CelestialPosition) {
        model.clearForCameraChange()
        model.setRotation(
            yaw: Float(body.azimuth - context.scene.heading),
            pitch: Float(body.altitude - context.scene.pitch))
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
