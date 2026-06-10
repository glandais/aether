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
| Canvas (`CanvasModel`) | `layers` (chaque `CloudLayer` → `genus`, `BrushStroke[]` → points + `StrokeCamera`, `coverageBias`, `opacity`, `isVisible`), `viewYaw, viewPitch, brushRadius, brushSoftness` |
| Surcharges (`CanvasView`) | `hourOverride, dateOverride, coordinateOverride, timeZoneIdentifier (du fuseau choisi), fovOverride` |
| Format | `version` (politique de version ci-dessous) |

### Schéma v2 — calques (multi-coquilles)

Le modèle multi-coquilles (cf. [`SHELLS.md`](SHELLS.md)) remplace les `cubes` par
des **calques** : `version` passe à **2**. Chaque `CloudLayer` persisté porte son
genre (`cumulus`/`altocumulus`/`cirrus`), ses traits et ses **surcharges météo
par calque** (`coverageBias`, `opacity`, `isVisible`). À la réouverture, les
traits sont **re-cuits dans l'atlas de couverture** par le même chemin que la
peinture live (`CoverageBaker`) — enregistrer puis rouvrir rend à l'identique. Les
surcharges sauvegardées priment sur les défauts météo de la scène : un calque
rechargé n'hérite **pas** des défauts courants (il garde son opacité/visibilité).

### Politique de version

- **Pas de rétrocompatibilité** (décision actée, `SHELLS.md` §10/§11) : l'app
  n'étant pas publiée, le schéma a fait un **bump franc 1 → 2** sans migration.
- Un fichier d'une **autre version** — v1 (cubes) comme un schéma postérieur
  (futur v3) — est **refusé proprement** : `decode(from:)` lit d'abord la seule
  `version` puis lève `AetherDocumentError.unsupportedVersion`
  — pas de crash, pas de document à moitié chargé. La galerie affiche un message
  sobre localisé (`gallery.openErrorVersion`, fr + en) ; un contenu illisible
  (JSON corrompu, version absente) donne `AetherDocumentError.corrupted` et le
  message générique (`gallery.openError`).
- `AetherDocument.currentVersion` est la **source unique** de la version courante ;
  le `Payload.version` la prend par défaut à l'écriture.

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
- **`Codable`** sur les types Domain purs (`GeoCoordinate`, `Scene`,
  `CloudParameters`, `SeaSurface`, `BrushStroke`/`StrokeCamera`, `CloudLayer`/
  `CloudGenus`). Les `SIMD2/SIMD3<Float>` sont déjà `Codable` (conteneur scalaire).

### Flux

- **Enregistrer** (canvas → panneau « More ») : `presentSave()` construit l'
  `AetherDocument` depuis `context` + `model` + les surcharges, puis ouvre
  `.fileExporter` (nom par défaut = titre de la scène).
- **Ouvrir** (galerie, bouton de barre d'outils) : `.fileImporter` →
  lecture de l'URL (ressource protégée par le bac à sable) →
  `AetherDocument.decode(from:)` (contrôle de version) → `makeLoaded()` →
  `onSelect(context, restored)`. Une erreur typée (`unsupportedVersion`/
  `corrupted`) bascule sur l'alerte localisée correspondante.
- **`RootView`** porte le `SceneContext` **et** le `RestoredCanvasState`
  optionnel, transmis à `CanvasView(context:restored:)`. Le `.id(context.id)`
  garantit une **nouvelle identité** par scène ouverte (état `@State` réamorcé
  proprement). `CanvasView.init` ensemence les `@State` (modèle + surcharges)
  dès la première frame — pas d'image transitoire.
- **`CanvasModel.load(layers:…)`** remplace les calques et l'orientation et
  réinitialise l'historique (pas d'annulation à travers un chargement). Les
  surcharges par calque sont posées telles quelles ; la couverture est **re-cuite
  dans l'atlas** (`CoverageBaker`) depuis les traits des calques, chaque
  `BrushStroke` portant sa `StrokeCamera`.

## Vérification

- **Test unitaire** `AetherDocumentTests` (`Tests/AetherTests`) : capture → JSON
  → décodage → reconstruction ; assertions sur l'égalité des **calques** (genre,
  traits, surcharges météo, visibilité), des surcharges d'instant/lieu, de la
  scène, des paramètres de rendu et des dimensions de l'image embarquée. Des tests
  vérifient aussi le **refus** d'un fichier `version: 1` (et d'un futur
  `version: 3`) avec `unsupportedVersion(found:)`, et que `load(layers:)` n'écrase
  pas les surcharges par calque avec les défauts météo d'une scène différente.
- **Vérification visuelle** sur simulateur : peindre, régler l'heure / le zoom,
  **Enregistrer** vers `Files` ; relancer, **Ouvrir un ciel** depuis la galerie,
  comparer la capture à celle d'avant sauvegarde.
