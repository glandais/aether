import Observation
import simd

/// État du canvas de peinture : les **cubes** de nuage déjà peints. Chaque cube
/// est ancré sur une direction de regard et porte ses traits (en coordonnées
/// normalisées [0,1]², origine en haut à gauche). Le rendu consomme `cubes`.
///
/// Plusieurs cubes : il existe toujours un **cube courant** (le dernier). Tout
/// trait y est ajouté. Quand le regard a changé depuis la création du cube
/// courant, le prochain trait ouvre un **nouveau** cube ancré sur le regard
/// courant (qui devient le cube courant) ; on ne revient jamais dans un cube
/// antérieur.
///
/// Historique annuler/rétablir à la granularité du trait : chaque trait achevé
/// (et chaque effacement) est une action réversible — on instantané la liste de
/// cubes. Le `Renderer` repeint automatiquement (mise à jour incrémentale par
/// cube : ajout comme retrait).
@MainActor
@Observable
final class CanvasModel {
    private(set) var cubes: [CloudCube] = []
    /// Calques du modèle multi-coquilles (cf. `docs/SHELLS.md`). Chaque calque
    /// est une coquille concentrique éditable ; le calque actif (`activeGenus`)
    /// reçoit tout nouveau trait. Renseigné **en parallèle** des `cubes` tant que
    /// le rendu visible reste celui des cubes (suppression à l'étape 8). La
    /// couverture directionnelle (`Renderer`) se cuit depuis ces traits.
    private(set) var layers: [CloudLayer] = []
    /// Genre du calque actif (étage de peinture). Défaut : cumulus (étage bas).
    var activeGenus: CloudGenus = .cumulus
    private(set) var isDrawing = false

    /// Défauts par calque issus de la météo statique du paysage (`CloudParameters`
    /// → `WeatherSnapshot`, cf. `docs/SHELLS.md` §4/§12). Appliqués **à la création
    /// d'un calque** : un paysage couvert ouvre des calques plus pleins (biais de
    /// couverture positif) et plus opaques, un paysage dégagé l'inverse. Les
    /// réglages par calque (opacité de l'étape 5) les surchargent ensuite. Décision
    /// §12 : mêmes valeurs par défaut pour tous les calques.
    private var defaultCoverageBias: Float = 0
    private var defaultOpacity: Float = 1

    /// Rayon et adoucissement du pinceau, en coordonnées normalisées.
    var brushRadius: Float = 0.08
    var brushSoftness: Float = 0.55

    /// Mode rotation du regard : quand actif, le drag pivote la vue au lieu de
    /// peindre. Piloté par le bouton « Pivoter la vue ».
    var isRotating = false

    /// Orientation du regard (radians) : lacet (libre) + tangage (clampé).
    private(set) var viewYaw: Float = 0
    private(set) var viewPitch: Float = 0

    /// Limite de tangage (~80°) : empêche la bascule du regard.
    private static let maxPitch: Float = 1.4

    /// Distance minimale entre deux points d'un même trait (décimation).
    private let minSpacing: Float = 0.012

    /// Au-delà de ce cosinus d'écart angulaire entre deux regards, on les
    /// considère identiques (même cube). Les deux regards sont alors bit-à-bit
    /// égaux en pratique ; la marge absorbe le bruit flottant.
    private static let sameViewCos: Float = 0.99999

    /// Instantané réversible : cubes (rendu visible) **et** calques (couverture
    /// directionnelle), cuits en parallèle pendant la transition multi-coquilles.
    private struct Snapshot {
        var cubes: [CloudCube]
        var layers: [CloudLayer]
    }

    /// Piles d'historique : instantanés de l'état (cubes + calques).
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Tous les traits, aplatis (lecture seule) : pour l'état d'édition de l'UI
    /// (y a-t-il à effacer ?). Un cube porte toujours ≥ 1 trait, donc
    /// `!cubes.isEmpty` suffit aussi.
    var strokes: [BrushStroke] { cubes.flatMap(\.strokes) }

    func beginStroke(at point: SIMD2<Float>, camera: StrokeCamera) {
        recordHistory()  // instantané d'avant-trait : l'annulation y revient
        let stroke = BrushStroke(
            points: [point], radius: brushRadius, softness: brushSoftness, camera: camera)
        // Le regard a-t-il changé depuis la création du cube courant ? Si oui (ou
        // s'il n'y a pas encore de cube), on ouvre un nouveau cube ancré sur le
        // regard courant — sauf au plafond, où l'on reste dans le cube courant.
        let sameView = cubes.last.map {
            dot($0.anchorForward, camera.forward) > Self.sameViewCos
        } ?? false
        if !sameView && cubes.count < CloudCube.maxCount {
            cubes.append(CloudCube(anchorForward: camera.forward, strokes: [stroke]))
        } else {
            // Cube courant : même regard, ou plafond atteint (repli sans perte).
            cubes[cubes.count - 1].strokes.append(stroke)
        }
        // Modèle multi-coquilles : le trait va aussi dans le calque actif (créé à
        // la volée), cuit en couverture directionnelle par le Renderer.
        appendStrokeToActiveLayer(stroke)
        isDrawing = true
    }

    func extendStroke(to point: SIMD2<Float>) {
        guard let ci = cubes.indices.last,
              var stroke = cubes[ci].strokes.last else { return }
        if let last = stroke.points.last, distance(last, point) < minSpacing {
            return
        }
        stroke.points.append(point)
        cubes[ci].strokes[cubes[ci].strokes.count - 1] = stroke
        // Reflète l'allongement dans le calque actif (dernier trait du calque).
        extendActiveLayerStroke(with: point)
    }

    /// Ajoute un trait au calque actif (créé si absent), ou — comme pour les cubes
    /// — à un calque existant du même genre. Garde calques et cubes synchrones. Un
    /// calque neuf hérite des défauts météo (`defaultCoverageBias`/`defaultOpacity`).
    private func appendStrokeToActiveLayer(_ stroke: BrushStroke) {
        if let li = layers.firstIndex(where: { $0.genus == activeGenus }) {
            layers[li].strokes.append(stroke)
        } else {
            layers.append(CloudLayer(
                genus: activeGenus, strokes: [stroke],
                coverageBias: defaultCoverageBias, opacity: defaultOpacity))
        }
    }

    /// Renseigne les défauts par calque depuis la météo statique du paysage. À
    /// appeler à l'ouverture de la scène, **avant tout trait** : les calques créés
    /// ensuite héritent de ces valeurs (décision §12). L'opacité est ramenée au
    /// domaine du curseur (0…1) — l'échelle de densité météo ≈ 0,6…1,4 sature à 1
    /// pour les paysages couverts, baisse pour les dégagés.
    func applySceneDefaults(_ parameters: CloudParameters) {
        defaultCoverageBias = parameters.coverageBias
        defaultOpacity = min(max(parameters.densityScale, 0), 1)
    }

    /// Allonge le dernier trait du calque actif (miroir d'`extendStroke`).
    private func extendActiveLayerStroke(with point: SIMD2<Float>) {
        guard let li = layers.firstIndex(where: { $0.genus == activeGenus }),
              var stroke = layers[li].strokes.last else { return }
        stroke.points.append(point)
        layers[li].strokes[layers[li].strokes.count - 1] = stroke
    }

    func endStroke() {
        isDrawing = false
    }

    /// Sélectionne le calque actif (étage de peinture). Pure sélection d'outil —
    /// pas une action réversible, donc hors historique.
    func selectGenus(_ genus: CloudGenus) {
        activeGenus = genus
    }

    /// Le calque existant pour ce genre, s'il en porte un (un trait a déjà été
    /// déposé à cet étage). `nil` tant que l'étage est vierge.
    func layer(for genus: CloudGenus) -> CloudLayer? {
        layers.first { $0.genus == genus }
    }

    /// Bascule la visibilité d'un calque (étage éteint/allumé à l'écran).
    /// Instantané réversible : le toggle s'annule comme un trait.
    func setVisible(_ visible: Bool, for genus: CloudGenus) {
        guard let li = layers.firstIndex(where: { $0.genus == genus }),
              layers[li].isVisible != visible else { return }
        recordHistory()
        layers[li].isVisible = visible
    }

    /// Instantané d'avant-réglage d'opacité, à appeler **une fois** au début d'un
    /// glissement (l'annulation revient alors à l'opacité d'avant-geste, pas à
    /// chaque pas intermédiaire). Sans effet si le calque n'existe pas.
    func snapshotForOpacity(of genus: CloudGenus) {
        guard layers.contains(where: { $0.genus == genus }) else { return }
        recordHistory()
    }

    /// Règle l'opacité d'un calque (extinction de la coquille). Écriture continue
    /// pendant le glissement ; l'historique est instantané à part
    /// (`snapshotForOpacity`), pour ne pas empiler une action par frame.
    func setOpacity(_ opacity: Float, for genus: CloudGenus) {
        guard let li = layers.firstIndex(where: { $0.genus == genus }) else { return }
        layers[li].opacity = opacity
    }

    func clear() {
        guard !cubes.isEmpty else { return }
        recordHistory()
        cubes = []
        layers = []
        isDrawing = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(cubes: cubes, layers: layers))
        cubes = previous.cubes
        layers = previous.layers
        isDrawing = false
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(cubes: cubes, layers: layers))
        cubes = next.cubes
        layers = next.layers
        isDrawing = false
    }

    /// Réamorce l'état depuis un fichier `.aether` v2 rechargé : remplace les
    /// **calques** et l'orientation, réinitialise l'historique (pas d'annulation à
    /// travers un chargement). Le tangage est reclampé par sécurité.
    ///
    /// Les calques sont posés **tels quels** : leurs surcharges météo
    /// (`coverageBias`/`opacity`/`isVisible`) sauvegardées priment sur les défauts
    /// de scène — un calque rechargé n'hérite pas des défauts météo courants.
    /// Les cubes (rendu visible jusqu'à l'étape 8) sont reconstruits depuis les
    /// traits des calques, chaque trait portant déjà sa `StrokeCamera` : la
    /// peinture se reprojette à l'identique.
    func load(
        layers: [CloudLayer], viewYaw: Float, viewPitch: Float,
        brushRadius: Float, brushSoftness: Float
    ) {
        self.layers = layers
        self.cubes = Self.rebuildCubes(from: layers.flatMap(\.strokes))
        self.viewYaw = viewYaw
        self.viewPitch = min(max(viewPitch, -Self.maxPitch), Self.maxPitch)
        self.brushRadius = brushRadius
        self.brushSoftness = brushSoftness
        isDrawing = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Regroupe une liste plate de traits en cubes, en suivant la même règle que
    /// `beginStroke` : un nouveau cube naît dès que la pose de regard d'un trait
    /// s'écarte de celle du cube courant (au-delà de `sameViewCos`), plafonnée à
    /// `CloudCube.maxCount`. Conserve la parité du rendu cube à la réouverture.
    private static func rebuildCubes(from strokes: [BrushStroke]) -> [CloudCube] {
        var cubes: [CloudCube] = []
        for stroke in strokes {
            let forward = stroke.camera.forward
            let sameView = cubes.last.map {
                dot($0.anchorForward, forward) > sameViewCos
            } ?? false
            if !sameView && cubes.count < CloudCube.maxCount {
                cubes.append(CloudCube(anchorForward: forward, strokes: [stroke]))
            } else {
                cubes[cubes.count - 1].strokes.append(stroke)
            }
        }
        return cubes
    }

    /// Oriente le regard. Le lacet est libre (panoramique) ; le tangage est
    /// clampé à ±`maxPitch` pour éviter la bascule.
    func setRotation(yaw: Float, pitch: Float) {
        viewYaw = yaw
        viewPitch = min(max(pitch, -Self.maxPitch), Self.maxPitch)
    }

    /// Empile l'état courant et invalide la pile de rétablissement (nouvelle
    /// branche d'historique).
    private func recordHistory() {
        undoStack.append(Snapshot(cubes: cubes, layers: layers))
        redoStack.removeAll()
    }
}
