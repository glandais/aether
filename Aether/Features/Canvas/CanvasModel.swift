import Observation
import simd

/// État du canvas de peinture : les **calques** de nuage déjà peints (modèle
/// multi-coquilles, cf. `docs/SHELLS.md`). Chaque calque est une coquille
/// concentrique éditable, désignée par son genre (étage), et porte ses traits
/// (en coordonnées normalisées [0,1]², origine en haut à gauche). Le rendu
/// consomme `layers` : la couverture directionnelle s'en cuit, l'empilement des
/// coquilles crée les étages.
///
/// Le calque actif (`activeGenus`) reçoit tout nouveau trait ; on crée le calque
/// à la volée au premier trait d'un genre. Plus de cubes ancrés sur le regard :
/// le regard oriente la peinture, il ne crée plus de domaine.
///
/// Historique annuler/rétablir à la granularité du trait : chaque trait achevé
/// (et chaque effacement / toggle de visibilité / réglage d'opacité) est une
/// action réversible — on instantané la liste de calques. Le `Renderer` recuit
/// la couverture (mise à jour incrémentale : ajout comme retrait).
@MainActor
@Observable
final class CanvasModel {
    /// Calques du modèle multi-coquilles (cf. `docs/SHELLS.md`). Chaque calque
    /// est une coquille concentrique éditable ; le calque actif (`activeGenus`)
    /// reçoit tout nouveau trait. La couverture directionnelle (`Renderer`) se
    /// cuit depuis ces traits.
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

    /// Piles d'historique : instantanés de la liste de calques.
    private var undoStack: [[CloudLayer]] = []
    private var redoStack: [[CloudLayer]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Y a-t-il au moins un trait peint (tous calques confondus) ? Pour l'état
    /// d'édition de l'UI (y a-t-il à effacer ?), sans allouer de tableau aplati.
    var hasStrokes: Bool { layers.contains { !$0.strokes.isEmpty } }

    func beginStroke(at point: SIMD2<Float>, camera: StrokeCamera) {
        recordHistory()  // instantané d'avant-trait : l'annulation y revient
        let stroke = BrushStroke(
            points: [point], radius: brushRadius, softness: brushSoftness, camera: camera)
        // Le trait va dans le calque actif (créé à la volée), cuit en couverture
        // directionnelle par le Renderer.
        appendStrokeToActiveLayer(stroke)
        isDrawing = true
    }

    func extendStroke(to point: SIMD2<Float>) {
        guard let li = layers.firstIndex(where: { $0.genus == activeGenus }),
              let last = layers[li].strokes.last?.points.last,
              distance(last, point) >= minSpacing else { return }
        layers[li].strokes[layers[li].strokes.count - 1].points.append(point)
    }

    /// Ajoute un trait au calque actif (créé si absent). Un calque neuf hérite des
    /// défauts météo (`defaultCoverageBias`/`defaultOpacity`).
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

    func endStroke() {
        isDrawing = false
    }

    /// Annule le trait en cours : un second doigt s'est posé (geste caméra), le
    /// trait amorcé était accidentel. Restaure l'instantané empilé par
    /// `beginStroke` SANS toucher la pile de rétablissement (ce n'est pas une
    /// action utilisateur réversible, juste l'annulation d'une amorce).
    func cancelStroke() {
        guard isDrawing, let previous = undoStack.popLast() else {
            isDrawing = false
            return
        }
        layers = previous
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

    /// Opacité du calque d'un genre (1 par défaut si l'étage est vierge), exposée
    /// en subscript pour un `Binding` naturel via `@Bindable` (`$model[opacityFor:]`).
    /// L'écriture délègue à `setOpacity`, sans instantané d'historique (celui-ci
    /// reste piloté à part par `snapshotForOpacity` au début du glissement).
    subscript(opacityFor genus: CloudGenus) -> Float {
        get { layer(for: genus)?.opacity ?? 1 }
        set { setOpacity(newValue, for: genus) }
    }

    func clear() {
        guard !layers.isEmpty else { return }
        recordHistory()
        layers = []
        isDrawing = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(layers)
        layers = previous
        isDrawing = false
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(layers)
        layers = next
        isDrawing = false
    }

    /// Réamorce l'état depuis un fichier `.aether` v2 rechargé : remplace les
    /// **calques** et l'orientation, réinitialise l'historique (pas d'annulation à
    /// travers un chargement). Le tangage est reclampé par sécurité.
    ///
    /// Les calques sont posés **tels quels** : leurs surcharges météo
    /// (`coverageBias`/`opacity`/`isVisible`) sauvegardées priment sur les défauts
    /// de scène — un calque rechargé n'hérite pas des défauts météo courants.
    /// Chaque trait portant déjà sa `StrokeCamera`, la peinture se reprojette à
    /// l'identique.
    func load(
        layers: [CloudLayer], viewYaw: Float, viewPitch: Float,
        brushRadius: Float, brushSoftness: Float
    ) {
        self.layers = layers
        self.viewYaw = viewYaw
        self.viewPitch = min(max(viewPitch, -Self.maxPitch), Self.maxPitch)
        self.brushRadius = brushRadius
        self.brushSoftness = brushSoftness
        isDrawing = false
        undoStack.removeAll()
        redoStack.removeAll()
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
        undoStack.append(layers)
        redoStack.removeAll()
    }
}
