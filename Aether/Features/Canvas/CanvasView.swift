import Foundation
import SwiftUI
import simd

/// Hôte du canvas de rendu volumétrique, pour un paysage donné. La photo est
/// affichée à son propre aspect (lettrage) ; les paysages curés abstraits
/// occupent le plein cadre. L'utilisateur peint des silhouettes de nuages,
/// éclairées selon le lieu/cadrage de la scène et l'heure choisie (le curseur
/// déplace le soleil et la lune ; le nuage se rallume en conséquence).
/// Sens du défilement automatique du temps (exclusif : un seul actif).
enum AutoPlay {
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

struct CanvasView: View {
    let context: SceneContext
    /// Harnais de capture : masque toute l'interface (y compris la pastille
    /// « Options ») pour un ciel plein cadre.
    private let chromeHidden: Bool

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
    /// Éphéméride présentée (lever/coucher, phase). Figée à l'ouverture : la
    /// feuille ne se recalcule pas à chaque tick de défilement derrière elle.
    @State private var ephemerisPresentation: EphemerisPresentation?
    /// Résolution « ici & maintenant » en cours (position GPS + fuseau).
    @State private var isResolvingHereNow = false
    /// Défilement automatique du temps (aucun / avance / recul). Exclusif.
    @State private var autoPlay: AutoPlay = .none
    /// Multiplicateur de vitesse du défilement (1, 2, 4, 8, 16). 1× = 0,25 h/s.
    @State private var autoPlaySpeed = 1
    /// Panneau d'outil explicitement ouvert. Seul « More » (ciel + lieu) s'y
    /// pose : le panneau peinture s'affiche de lui-même tant qu'on peint, sans
    /// passer par cet état. Rendu en carte flottante **à côté** des pastilles
    /// (pas d'expansion inline qui repousserait la colonne).
    @State private var activePanel: ToolPanel?
    /// Révèle toutes les options (retour, regard, pinceau, heure). Déployé à
    /// l'ouverture : l'outil dessin actif est ainsi visible d'emblée ; on peut
    /// replier d'un geste pour dégager le ciel.
    @State private var showOptions: Bool
    /// Hauteur compacte (paysage iPhone) : la palette passe en rangée
    /// horizontale, la largeur (abondante) absorbant les pastilles.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Orientation du regard au début d'un drag de rotation (lacet, tangage).
    @State private var rotationAnchor: SIMD2<Float>?
    /// Champ de vision choisi (radians). `nil` = FOV d'origine de la scène.
    @State private var fovOverride: Double?
    /// FOV au début d'un pincement (baseline du geste de zoom).
    @State private var fovAnchor: Double?
    /// Étoiles visibles résolues pour le lieu/heure courant, et leur révision.
    /// Recalculées seulement quand `starKey` change (cf. `.task`), jamais par
    /// frame de rotation/zoom.
    @State private var starField: [VisibleStar] = []
    @State private var starRevision = 0
    /// Document préparé pour l'export, et présentation du sélecteur de fichier.
    @State private var saveDocument: AetherDocument?
    @State private var showSaveExporter = false
    /// Mémoïse la part coûteuse (astro-dépendante) de l'éclairage : recalculée
    /// seulement au changement d'heure/lieu, pas à chaque `body` (trait, réglage,
    /// rotation). Classe non observable → l'appeler depuis `body` ne crée pas de
    /// dépendance d'invalidation.
    @State private var lightCache = AstroLightCache()

    /// Construit la vue, éventuellement réamorcée depuis un fichier `.aether`
    /// rechargé : les traits, le regard, le pinceau et les surcharges
    /// (heure/jour/lieu/fuseau/FOV) sont appliqués d'emblée, sans frame transitoire.
    init(context: SceneContext, restored: RestoredCanvasState? = nil, chromeHidden: Bool = false) {
        self.context = context
        self.chromeHidden = chromeHidden
        let model = CanvasModel()
        // Défauts par calque issus de la météo statique du paysage (étape 6) :
        // posés avant tout trait neuf. Les calques rechargés (`load`) portent leurs
        // propres surcharges sauvegardées et n'en héritent pas.
        model.applySceneDefaults(context.cloudParameters)
        if let restored {
            model.load(
                layers: restored.layers, viewYaw: restored.viewYaw, viewPitch: restored.viewPitch,
                brushRadius: restored.brushRadius, brushSoftness: restored.brushSoftness)
        }
        _model = State(initialValue: model)
        _hourOverride = State(initialValue: restored?.hourOverride)
        _dateOverride = State(initialValue: restored?.dateOverride)
        _coordinateOverride = State(initialValue: restored?.coordinateOverride)
        _timeZoneOverride = State(initialValue: restored?.timeZoneOverride)
        _fovOverride = State(initialValue: restored?.fovOverride)
        // Harnais de capture : masque toute l'interface pour un ciel plein cadre.
        _showOptions = State(initialValue: !chromeHidden)
    }

    /// Catalogue BSC5 chargé une seule fois (paresseux, partagé).
    private static let starCatalog: [Star] = StarCatalog.load()

    /// Plage de FOV au pincement (≈25°…100°).
    private static let minFieldOfView = 0.44
    private static let maxFieldOfView = 1.75

    /// Vitesse de base du défilement automatique (heures par seconde réelle) au
    /// multiplicateur 1×. Les multiplicateurs cycliques vivent dans `TimeBar`.
    private static let baseHoursPerSecond = 0.25

    // Dépendances exposées via leur protocole (cf. CLAUDE.md : SwiftAA / tzf
    // cachés derrière une abstraction pour la testabilité). `SwiftAAAstroService`
    // est une struct sans état ; les services **avec** état (fuseau tzf à cache
    // paresseux, `CLLocationManager`) vivent en `@State` pour persister à travers
    // les ré-inits de la vue au lieu d'être réalloués à chaque fois.
    private let astro: AstroService = SwiftAAAstroService()
    private let atmosphere = Atmosphere.earth
    @State private var timeZoneService: TimeZoneService = TzfTimeZoneService()
    @State private var locationService = CoreLocationService()

    /// Panneau d'outil ouvert. Exclusif : un seul à la fois, pour ne pas
    /// encombrer le ciel ni déborder en paysage. `paint` réunit la peinture
    /// (sélection d'étage, visibilité, opacité, réglages de pinceau) ; il
    /// s'affiche de lui-même tant qu'on peint, sans bascule. `more` regroupe les
    /// réglages contextuels (ciel, lieu) sous un seul bouton, façon « More » HIG.
    /// `fileprivate` (non `private`) car traversé par la carte de panneau rendue
    /// dans l'extension `Panneaux & gestes`.
    fileprivate enum ToolPanel {
        case paint, more
    }

    /// Éclairage résolu pour l'instant courant : direction, couleur, ambiance.
    fileprivate struct ResolvedLight {
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
            if showOptions && !chromeHidden {
                VStack(spacing: 14) {
                    Spacer()
                    TimeBar(
                        hour: hourBinding, isDaytime: light.isDaytime, timeLabel: timeLabel,
                        autoPlay: $autoPlay, autoPlaySpeed: $autoPlaySpeed)
                }
                .padding(.bottom, 28)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !chromeHidden {
                toolPalette(light: light)
                    .padding(.trailing, 16).padding(.top, 8)
            }
        }
        // Recalcul des étoiles hors `body` : seulement au changement de lieu/heure
        // (bucket ~60 s, élargi en défilement), pas à chaque frame de rotation/zoom.
        .task(id: starKey) { await recomputeStars() }
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
                Task {
                    let zone = await timeZoneService.timeZone(for: coordinate)
                    // Anti-course : n'appliquer que si le lieu n'a pas changé
                    // depuis le lancement de cette résolution (complétions
                    // possiblement dans le désordre).
                    if coordinateOverride == coordinate { timeZoneOverride = zone }
                }
            }
        }
        .sheet(item: $ephemerisPresentation) { presentation in
            EphemerisView(ephemeris: presentation.ephemeris, timeZone: presentation.timeZone)
        }
        .fileExporter(
            isPresented: $showSaveExporter, document: saveDocument,
            contentType: .aetherScene, defaultFilename: context.scene.title
        ) { _ in }
    }

    /// Prépare le document de l'instant (état complet) puis ouvre le sélecteur
    /// d'enregistrement. Échec silencieux si le paysage ne s'encode pas (rare).
    private func presentSave() {
        saveDocument = AetherDocument(
            context: context, model: model,
            hourOverride: hourOverride, dateOverride: dateOverride,
            coordinateOverride: coordinateOverride, timeZoneOverride: timeZoneOverride,
            fovOverride: fovOverride)
        showSaveExporter = saveDocument != nil
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
            timeBucket: Int(effectiveDate.timeIntervalSince1970 / starBucketSeconds))
    }

    /// Largeur de la tranche de temps du recalcul des étoiles. À l'arrêt, 60 s
    /// (rotation sidérale négligeable). En défilement, on l'élargit au prorata du
    /// débit simulé pour plafonner le recalcul (~2 par seconde réelle) tout en
    /// gardant des étoiles qui se déplacent dans le timelapse.
    private var starBucketSeconds: Double {
        guard autoPlay != .none else { return 60 }
        let simSecondsPerRealSecond = Self.baseHoursPerSecond * Double(autoPlaySpeed) * 3600
        return max(60, simSecondsPerRealSecond / 2)
    }

    /// Résout les directions monde des étoiles visibles pour l'instant courant. La
    /// boucle sur les ~9000 étoiles (pure) tourne hors du main actor ; le résultat
    /// est réassigné sur le main actor.
    private func recomputeStars() async {
        let coordinate = effectiveCoordinate
        let catalog = Self.starCatalog
        let sidereal = StarCatalog.localSiderealTime(
            date: effectiveDate, longitudeEast: coordinate.longitude)
        let latitude = coordinate.latitude
        let stars = await Task.detached {
            StarCatalog.visibleStars(catalog, latitude: latitude, siderealTime: sidereal)
        }.value
        starField = stars
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
                brushBubble.transition(reveal)
                // Annuler / rétablir / effacer : pastilles principales directes
                // (pas de sous-menu), révélées seulement dès qu'il y a à éditer.
                if hasEdits {
                    actionBubble("arrow.uturn.backward", "action.undo", enabled: model.canUndo) { model.undo() }
                        .transition(reveal)
                    actionBubble("arrow.uturn.forward", "action.redo", enabled: model.canRedo) { model.redo() }
                        .transition(reveal)
                    actionBubble("trash", "action.clear", enabled: model.hasStrokes) { model.clear() }
                        .transition(reveal)
                }
                moreBubble.transition(reveal)
            }
        }
        if isCompactHeight {
            HStack(alignment: .top, spacing: 10) { bubbles }
        } else {
            VStack(alignment: .trailing, spacing: 10) { bubbles }
        }
    }

    /// Carte du panneau visible, en matériau translucide : « More » s'il est
    /// ouvert ; sinon, en mode dessin (options déployées), la carte peinture
    /// (sélection d'étage, visibilité, opacité, réglages de pinceau) — toujours
    /// présente tant qu'on peint, sans bascule.
    @ViewBuilder
    private func activePanelCard(light: ResolvedLight) -> some View {
        let panel: ToolPanel? =
            activePanel == .more ? .more
            : (showOptions && !model.isRotating ? .paint : nil)
        if let panel {
            panelContent(panel, light: light)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
        }
    }

    /// Paysage iPhone (la palette passe à l'horizontale).
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    /// Sélecteur du mode « regard » : mutuellement exclusif du mode dessin
    /// (jumeau du bouton pinceau). Sélectionner le regard sort du dessin.
    private var rotateButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.isRotating = true }
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
    /// La moitié coûteuse (positions astro + intégrales de ciel) est mémoïsée dans
    /// `lightCache` (invariante tant que l'heure/le lieu ne bougent pas) ; seule la
    /// part « regard » (mélange des directions caméra) est recalculée ici à chaque
    /// `body`, car elle suit le lacet/tangage.
    private var resolvedLight: ResolvedLight {
        let cached = lightCache.resolved(
            date: effectiveDate, coordinate: effectiveCoordinate,
            astro: astro, atmosphere: atmosphere, exposure: context.skyExposure)

        // Le regard de l'utilisateur (lacet + tangage) s'ajoute à l'attitude de
        // la scène : le soleil/la lune tournent dans le repère caméra comme le
        // ciel (cohérence via la base partagée, cf. `CameraPose`).
        let gazeHeading = context.scene.heading + Double(model.viewYaw)
        let gazePitch = context.scene.pitch + Double(model.viewPitch)
        let sunDir = cached.sunPosition.cameraDirection(
            heading: gazeHeading, pitch: gazePitch, roll: context.scene.roll)
        let moonDir = cached.moonPosition.cameraDirection(
            heading: gazeHeading, pitch: gazePitch, roll: context.scene.roll)
        var direction = moonDir + (sunDir - moonDir) * cached.sunWeight
        // Soleil et lune opposés : le mélange peut s'annuler → repli sur le dominant.
        direction = length(direction) < 0.01
            ? (cached.sunWeight >= 0.5 ? sunDir : moonDir) : normalize(direction)

        return ResolvedLight(
            direction: direction, skySunDirection: cached.skySunDirection,
            sunDiscColor: cached.sunDiscColor, moonDiscColor: cached.moonDiscColor,
            color: cached.color, ambient: cached.ambient, groundLight: cached.groundLight,
            isDaytime: cached.isDaytime,
            moonSkyDirection: cached.moonSkyDirection,
            moonGlint: cached.moonGlint,
            nightWeight: cached.nightWeight,
            skyZenithRadiance: cached.skyZenithRadiance,
            skyHorizonRadiance: cached.skyHorizonRadiance,
            sunPosition: cached.sunPosition,
            moonPosition: cached.moonPosition)
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
            layers: model.layers,
            sunDirection: light.direction,
            skySunDirection: light.skySunDirection,
            sunDiscColor: light.sunDiscColor,
            moonDiscColor: light.moonDiscColor,
            atmosphere: atmosphere,
            groundLight: light.groundLight,
            sunColor: light.color,
            skyAmbient: light.ambient,
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
            // Couche de gestes UIKit : les `bounds` valent la taille réelle du
            // rendu (cadre lettré ou plein écran) pour normaliser les coordonnées
            // du pinceau. Un doigt peint (ou pivote en mode regard) ; deux doigts
            // pilotent toujours la caméra (glissement → rotation, pincement → zoom).
            CanvasGestureView(
                isRotating: model.isRotating,
                onPaintBegan: { loc, size in paint(at: loc, in: size) },
                onPaintMoved: { loc, size in paint(at: loc, in: size) },
                onPaintEnded: { model.endStroke() },
                onPaintCancelled: { model.cancelStroke() },
                onRotateBegan: { rotationAnchor = nil },
                onRotateChanged: { translation, size in rotate(translation: translation, in: size) },
                onRotateEnded: { rotationAnchor = nil },
                onZoomBegan: { fovAnchor = effectiveFieldOfView },
                onZoomChanged: { scale in
                    let target = (fovAnchor ?? effectiveFieldOfView) / Double(scale)
                    fovOverride = min(max(target, Self.minFieldOfView), Self.maxFieldOfView)
                },
                onZoomEnded: { fovAnchor = nil })
        }
        #if DEBUG
        .overlay(alignment: .leading) { DebugFPSBadge() }
        #endif

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

    /// Liaison d'heure locale (heures décimales) : lit l'heure effective, écrit
    /// la surcharge. Passée à `TimeBar`.
    private var hourBinding: Binding<Double> {
        Binding(get: { currentHour }, set: { hourOverride = $0 })
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

    /// Formateur « HH:mm » 24 h réutilisé (le fuseau est réglé à chaque appel —
    /// sûr car la vue est isolée au main actor). Éviter d'allouer un
    /// `DateFormatter` à chaque `body` (jusqu'à ~30×/s en défilement).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var timeLabel: String {
        let formatter = Self.timeFormatter
        formatter.timeZone = effectiveTimeZone
        return formatter.string(from: effectiveDate)
    }

    /// Y a-t-il quelque chose à éditer (trait en cours ou historique) ? Conditionne
    /// l'apparition du sous-menu d'édition.
    private var hasEdits: Bool {
        model.canUndo || model.canRedo || model.hasStrokes
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

    /// Sélecteur du mode « dessin » : mutuellement exclusif du mode regard.
    /// Sélectionner le dessin referme « More » pour laisser les réglages de
    /// pinceau visibles tant qu'on peint.
    private var brushBubble: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.isRotating = false
                // Referme « More » pour révéler la carte peinture (étages +
                // pinceau) tant qu'on peint.
                activePanel = nil
            }
        } label: {
            bubbleLabel("paintbrush.pointed", active: !model.isRotating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "group.brush", table: "Aether")))
    }

    /// Pastille « More » : regroupe les réglages contextuels (ciel, lieu).
    private var moreBubble: some View {
        bubbleToggle(.more, icon: "ellipsis", label: "group.more")
    }
}

// MARK: - Panneaux & gestes
//
// Contenu des cartes flottantes (peinture, « More »), contrôles par calque et
// pinceau, recadrage sur un astre, et les gestes de peinture / rotation. Séparés
// du corps principal pour garder `CanvasView` sous la limite de longueur.
extension CanvasView {
    /// Contenu du panneau actif.
    @ViewBuilder
    fileprivate func panelContent(_ panel: ToolPanel, light: ResolvedLight) -> some View {
        switch panel {
        case .paint:
            PaintPanel(model: model)
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
                        activePanel = nil
                        // Éphéméride figée à l'instant de l'ouverture (cf. `.sheet(item:)`).
                        ephemerisPresentation = EphemerisPresentation(
                            ephemeris: astro.ephemeris(at: effectiveCoordinate, date: effectiveDate),
                            timeZone: effectiveTimeZone)
                    }
                }
                Divider()
                positionPanel
                Divider()
                // Enregistre l'état courant dans un fichier `.aether` (ciel
                // complet, autonome) — rechargeable depuis la galerie.
                Button {
                    activePanel = nil
                    presentSave()
                } label: {
                    Label(
                        String(localized: "action.save", table: "Aether"),
                        systemImage: "square.and.arrow.down"
                    )
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            // Borne la largeur : sinon le Divider étire la carte sur toute la
            // largeur proposée (grand vide à gauche, surtout en paysage).
            .frame(width: 230)
        }
    }

    fileprivate func editButton(
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
    /// azimut/altitude (le tangage est clampé par `CanvasModel`). Le nuage étant
    /// à position réelle en monde, recentrer ne l'efface plus : il reste en place
    /// et entre/sort du cadre selon le regard.
    private func center(on body: CelestialPosition) {
        model.setRotation(
            yaw: Float(body.azimuth - context.scene.heading),
            pitch: Float(body.altitude - context.scene.pitch))
    }

    // MARK: - Météo

    /// Sensibilité de la rotation : un drag plein écran couvre ~`yawSpan` en
    /// lacet et ~`pitchSpan` en tangage (à caler par capture).
    private static let yawSpan: Float = 2.0
    private static let pitchSpan: Float = 1.6

    /// Peinture d'un trait (coordonnées normalisées au canvas). Le trait fige la
    /// pose de caméra courante : le Rendering projettera le trait dans le volume
    /// monde via cette pose, donc il reste en place quand on tourne ensuite.
    private func paint(at point: CGPoint, in size: CGSize) {
        let point = SIMD2(
            Float(point.x / size.width),
            Float(point.y / size.height)
        ).clamped()
        if model.isDrawing {
            model.extendStroke(to: point)
        } else {
            let basis = cameraPose.basis
            let camera = StrokeCamera(
                right: basis.right, up: basis.up, forward: basis.forward,
                tanHalfFov: tanHalfFieldOfView,
                aspect: Float(size.width / size.height))
            model.beginStroke(at: point, camera: camera)
        }
    }

    /// Rotation du regard. « Saisir le ciel » : drag à droite → le ciel glisse
    /// à droite (on tourne la tête à gauche) ; drag vers le bas → on lève les
    /// yeux. Le nuage étant à position réelle en monde, pivoter ne l'efface plus :
    /// on regarde autour / on l'orbite.
    private func rotate(translation: CGSize, in size: CGSize) {
        let anchor: SIMD2<Float>
        if let existing = rotationAnchor {
            anchor = existing
        } else {
            anchor = SIMD2(model.viewYaw, model.viewPitch)
            rotationAnchor = anchor
        }
        let yaw = anchor.x - Float(translation.width / size.width) * Self.yawSpan
        let pitch = anchor.y + Float(translation.height / size.height) * Self.pitchSpan
        model.setRotation(yaw: yaw, pitch: pitch)
    }
}

private extension SIMD2<Float> {
    /// Confine le point au canvas [0,1]² (un drag peut sortir des bords).
    func clamped() -> SIMD2<Float> {
        simd_clamp(self, .zero, .one)
    }
}
