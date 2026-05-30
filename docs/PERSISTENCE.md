# Persistance d'un ciel — fichiers `.aether`

Enregistrer l'état courant du canvas dans un fichier `.aether` autonome, puis le
recharger pour **reproduire exactement la même image**. Le résumé d'état et les
règles vivent dans [`../CLAUDE.md`](../CLAUDE.md) ; le pipeline de rendu dans
[`PIPELINE.md`](PIPELINE.md).

## Objectif

Le canvas était entièrement en mémoire : traits peints, instant choisi, lieu,
regard et zoom n'existaient que le temps de l'exécution. Revenir à la galerie ou
fermer l'app perdait tout. La persistance `.aether` permet à l'utilisateur de
**sauvegarder un ciel** (avec son paysage, ses nuages et son éclairage) dans un
fichier, et de le **rouvrir plus tard à l'identique**.

Le registre éditorial reste sobre : un bouton **Enregistrer** dans le canvas, une
entrée **Ouvrir un ciel** dans la galerie. Pas de gestion de projets, pas de
nommage imposé — le sélecteur système (`Files`) porte le choix de l'emplacement.

## Ce que contient un fichier `.aether`

Le rendu est une **fonction pure** d'un petit ensemble d'entrées ; tout le reste
(positions soleil/lune, étoiles, lumière, atmosphère) est **recalculé** depuis le
lieu et l'instant. On ne stocke donc que les entrées, jamais le dérivé.

| Source | Champs persistés |
|---|---|
| `Scene` | `id, title, landscapeAssetName, coordinate, date, heading, fieldOfView, pitch, roll, utcOffset, timeZoneIdentifier` |
| Contexte de rendu | `displayAspect, skyExposure, cloudParameters, sea` |
| Paysage | l'image de fond, **embarquée en PNG** |
| Canvas (`CanvasModel`) | `cubes` (chaque `CloudCube` → `BrushStroke[]` → points + `StrokeCamera`), `viewYaw, viewPitch, brushRadius, brushSoftness` |
| Surcharges (`CanvasView`) | `hourOverride, dateOverride, coordinateOverride, timeZoneIdentifier (du fuseau choisi), fovOverride` |
| Format | `version` (migration future) |

Notes :

- **Paysage embarqué.** Les paysages curés sont **procéduraux** (générés depuis
  une palette) et n'ont pas de référence stable ; l'import de photo est hors
  scope. Embarquer le PNG rend chaque fichier **autonome** et garantit un rendu
  identique au rechargement (quelques dizaines à centaines de Ko).
- **Caméra par trait.** Chaque `BrushStroke` porte déjà sa `StrokeCamera`
  (base monde + FOV + aspect au moment du trait) : les traits se reprojettent à
  l'identique quel que soit le regard courant. Aucune comptabilité caméra
  supplémentaire n'est nécessaire.
- **Regard et zoom.** `viewYaw`/`viewPitch`/`fovOverride` sont persistés car ils
  fixent la pose de caméra *courante* (ce qui est cadré) et la direction
  soleil/lune dans le repère caméra.
- **Non persisté.** L'UI transitoire (`autoPlay`, panneau actif, `showOptions`)
  et les piles annuler/rétablir ne sont pas stockées.

## Implémentation

### Format & type de document

- **`AetherDocument`** (`Features/Canvas/AetherDocument.swift`) — un
  `FileDocument` SwiftUI dont le `Payload` `Codable` est encodé en **JSON**
  (PNG inclus en base64). `readable`/`writableContentTypes = [.aetherScene]`.
  - `init(context:model:hourOverride:…)` (`@MainActor`) capture l'état courant.
  - `makeLoaded() -> LoadedScene?` reconstruit le `SceneContext` (scène + image
    décodée) et un `RestoredCanvasState`.
- **`UTType.aetherScene`** — type exporté `io.github.glandais.aether.scene`,
  extension `aether`, conforme à `public.data`. Déclaré dans un `Info.plist`
  **partiel** (`Resources/Info.plist` : `CFBundleDocumentTypes` +
  `UTExportedTypeDeclarations`) ; les clés générées (`GENERATE_INFOPLIST_FILE`)
  y sont **fusionnées** au build via `INFOPLIST_FILE` dans `project.yml`.
- **`CGImage+PNG.swift`** — encodage/décodage PNG via ImageIO.
- **`Codable`** ajouté aux types Domain purs (`GeoCoordinate`, `Scene`,
  `CloudParameters`, `SeaSurface`, `BrushStroke`/`StrokeCamera`, `CloudCube`).
  Les `SIMD2/SIMD3<Float>` sont déjà `Codable` (conteneur scalaire).

### Flux

- **Enregistrer** (canvas → panneau « More ») : `presentSave()` construit l'
  `AetherDocument` depuis `context` + `model` + les surcharges, puis ouvre
  `.fileExporter` (nom par défaut = titre de la scène).
- **Ouvrir** (galerie, bouton de barre d'outils) : `.fileImporter` →
  lecture de l'URL (ressource protégée par le bac à sable) → décodage du
  `Payload` → `makeLoaded()` → `onSelect(context, restored)`.
- **`RootView`** porte le `SceneContext` **et** le `RestoredCanvasState`
  optionnel, transmis à `CanvasView(context:restored:)`. Le `.id(context.id)`
  garantit une **nouvelle identité** par scène ouverte (état `@State` réamorcé
  proprement). `CanvasView.init` ensemence les `@State` (modèle + surcharges)
  dès la première frame — pas d'image transitoire.
- **`CanvasModel.load(…)`** remplace les cubes et l'orientation et réinitialise
  l'historique (pas d'annulation à travers un chargement).

## Vérification

- **Test unitaire** `AetherDocumentTests` (`Tests/AetherTests`) : capture → JSON
  → décodage → reconstruction ; assertions sur l'égalité des cubes (points +
  caméra par trait), des surcharges, de la scène, des paramètres de rendu et des
  dimensions de l'image embarquée.
- **Vérification visuelle** sur simulateur : peindre, régler l'heure / le zoom,
  **Enregistrer** vers `Files` ; relancer, **Ouvrir un ciel** depuis la galerie,
  comparer la capture à celle d'avant sauvegarde.
