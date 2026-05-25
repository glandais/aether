# Aether

> Application iOS contemplative de peinture de nuages volumétriques au-dessus d'un paysage.

## Étymologie

**Aether** — du grec αἰθήρ, divinité primordiale de l'air supérieur, du ciel
lumineux, et cinquième élément classique (au-delà des quatre éléments
terrestres). Le nom porte le concept : l'utilisateur agit sur le ciel.

**Registre éditorial** (UI + App Store) : sobre, atmosphérique, contemplatif.
Jamais « fun » ni enfantin.

## Vision

L'utilisateur choisit un paysage (galerie curée ou photo personnelle), peint des
silhouettes de nuages dans un canvas 2D simple, et un moteur de rendu
volumétrique Metal transforme ces silhouettes en nuages 3D plausibles, éclairés
par la position réelle du soleil et de la lune à l'endroit et à l'heure choisis.
La météo réelle à ce point/instant informe l'état initial.

Expérience visée : **contemplative, lente, satisfaisante**. Pas d'éditeur 3D
complexe — une poignée de sliders au maximum.

## Stack technique

- **Swift 6**, Xcode 16+ (dev : Xcode 26.5 / Swift 6.3), **iOS 17+ minimum**
- **SwiftUI** pour toute la chrome UI (gallery, palette, sliders, settings)
- **MetalKit** (`MTKView`) pour le canvas de rendu volumétrique
- **Metal Shading Language** : raymarching, bruit 3D, composition
- **WeatherKit** pour la météo (fallback **Open-Meteo**)
- **CoreLocation** + **PhotosUI** : photo perso + extraction EXIF GPS/timestamp
- **Vision** + modèle CoreML **Depth Anything** (converti) : depth estimation
  des photos sans LiDAR
- **ARKit / Scene depth** : photos prises avec LiDAR
- **SwiftAA** : positions soleil/lune (fallback impl. interne formules Meeus)
- **Swift Concurrency** (async/await, actors) — **pas de Combine, pas de RxSwift**
- **SwiftPM uniquement**, pas de CocoaPods
- **Tests** : XCTest + Swift Testing pour le métier (astro, weather mapping,
  brush→volume)

### Outillage projet

Le projet Xcode est **généré par XcodeGen** depuis `project.yml` (source de
vérité). `Aether.xcodeproj` est **git-ignoré** et régénéré via
`xcodegen generate`. Ajouter un fichier = créer le fichier, pas de churn du
`.pbxproj`.

- Bundle id : `io.github.glandais.aether`
- Icône : `Aether/Resources/Assets.xcassets/AppIcon.appiconset/icon.png` (1024², nuage au crépuscule)
- Signature : **automatique**, équipe `7Q49262697` (GABRIEL JEAN YVES ANNE LANDAIS),
  réglée dans `project.yml`

### Pièges connus

- Le Domain définit un type `Scene`, qui masque `SwiftUI.Scene`. Dans
  `AetherApp`, le `body` doit être typé `some SwiftUI.Scene` (qualifié).
- Le catalogue de strings est `Aether.xcstrings` → table **`Aether`**, pas la
  table `Localizable` par défaut. Toujours passer `tableName: "Aether"`
  (`Text("clé", tableName: "Aether")`, `String(localized:table:)`).

## Architecture en couches strictes

| Couche | Rôle | Dépend de |
|---|---|---|
| `Aether/App/` | entry point SwiftUI, navigation racine | Features |
| `Aether/Features/` | modules SwiftUI par feature (Canvas, Gallery, PhotoImport, Settings) | Domain, Services |
| `Aether/Rendering/` | pipeline Metal, shaders, volume textures | Domain **uniquement** |
| `Aether/Domain/` | modèles purs (`Scene`, `CloudVolume`, `BrushStroke`, `Lighting`, `WeatherSnapshot`, `CelestialPosition`) | **rien** |
| `Aether/Services/` | `WeatherService`, `AstroService`, `LocationService`, `DepthService` (protocoles + impl) | Domain |
| `Aether/Resources/` | assets, paysages curés, modèles CoreML | — |

**Règles de dépendance :**
- Domain ne dépend de rien.
- Services dépendent de Domain.
- Features dépendent de Domain et Services.
- Rendering dépend de Domain uniquement (pas de Service direct ; on lui passe des
  modèles déjà résolus).
- Toute dépendance externe (WeatherKit, CoreLocation, MLModel) est cachée
  derrière un protocole pour la testabilité.

## Pipeline de rendu — étapes successives, ne pas sauter

Références algorithmiques (papers + code d'exemple), indexées par étape :
[`BIBLIO.md`](BIBLIO.md).

Chaque étape doit être **visuellement vérifiable** avant de passer à la suivante.

1. MVP scaffold : `MTKView` affichant le paysage en texture de fond + quad de test
2. Raymarching d'un seul nuage analytique (sphère de bruit), éclairage directionnel fixe
3. Volume textures 3D, bruit Perlin-Worley précomputé en compute shader
4. Input du pinceau → champ de densité écrit dans le volume
5. Scattering atmosphérique : Beer-Lambert + Henyey-Greenstein
6. Composition avec depth map du paysage (occlusion correcte des reliefs)
7. Half-res raymarching + temporal reprojection (perf device bas/moyen de gamme)
8. Position soleil/lune dynamique alimentée par `AstroService`
9. Initialisation des paramètres depuis `WeatherService`

## Conventions

- Nommage Apple-style (`UpperCamelCase` types, `lowerCamelCase` membres, pas de préfixe)
- Pas de force-unwrap en prod sauf justifié en commentaire
- Pas de singleton sauf `App` — environnement SwiftUI ou injection explicite
- Strings UI dans `Aether.xcstrings` dès le début (fr + en min., registre sobre/atmosphérique)
- Logs via `Logger` (os.log), subsystem `io.github.glandais.aether`, **pas de `print`**
- Shaders Metal commentés en **anglais** ; code Swift commenté en **français** OK
- Un commit logique par responsabilité, **jamais « WIP » ni « fixes »**

## Hors scope

Partage social / comptes / backend · export vidéo ou animation · spécifique iPad
au-delà de l'universal de base · localisation au-delà de fr/en · IAP, analytics,
crash reporting.

## État d'avancement

**Étape 0 (bootstrap) — terminée.** Projet XcodeGen, structure en couches,
modèles Domain, protocoles Services, app SwiftUI lançable, test de fumée,
signature équipe. Build + test verts.

**Étape 1 (MVP scaffold) — terminée.**
- [x] Paysage placeholder rendu en texture de fond plein écran
  (`Background.metal`, dégradé crépusculaire généré dans `Renderer`)
- [x] Quad de test composité par-dessus en alpha blending (`TestQuad.metal`)
- [x] Vérifiée visuellement sur simulateur (iPhone 17 Pro)

Le paysage est un dégradé placeholder ; la galerie curée / l'import photo
viendront alimenter `landscapeTexture`.

**Étape 2 (raymarching nuage analytique) — terminée.**
- [x] `Cloud.metal` : raymarching d'une sphère de bruit (densité analytique
  fBm érodée façon Schneider), caméra pinhole fixe
- [x] Transmittance vue Beer-Lambert (Scratchapixel) + light-march vers un
  soleil directionnel fixe (auto-ombrage)
- [x] Composition « over » prémultipliée par-dessus le paysage
- [x] Vérifiée visuellement sur simulateur (iPhone 17 Pro)

Référence : Schneider 2015, Häggström, Quilez, Scratchapixel
(voir `BIBLIO.md`). La fonction de phase Henyey-Greenstein, le *powder* et le
scattering atmosphérique sont volontairement reportés à l'étape 5.

**Étape 3 (volume textures 3D Perlin-Worley) — terminée.**
- [x] `CloudNoise.metal` : compute kernel bakant une texture 3D 128³ tileable
  (R = Perlin-Worley, GBA = Worley à fréquences croissantes)
- [x] Précompute unique au lancement (`makeNoiseTexture`, `waitUntilCompleted`)
- [x] `Cloud.metal` échantillonne la texture 3D (sampler repeat) au lieu du fBm
  analytique ; base confinée par la sphère + érosion Worley des bords
- [x] Vérifiée visuellement sur simulateur (iPhone 17 Pro)

Référence : Schneider 2015/2017, Häggström, Bitsquid (voir `BIBLIO.md`).

**Étape 4 (pinceau → champ de densité) — terminée.**
- [x] `CanvasModel` (`@Observable`) + `DragGesture` : peinture de silhouettes
  en coordonnées normalisées, bouton « Effacer » (registre sobre)
- [x] `BrushPaint.metal` : compute kernel stampant les dabs dans un volume de
  densité 3D (96×96×48), silhouette extrudée en profondeur
- [x] `Cloud.metal` raymarche le volume peint (AABB) au lieu de la sphère ;
  bruit Perlin-Worley toujours en détail
- [x] Traits poussés SwiftUI → `Renderer.updateStrokes` → repeinte du volume
- [x] Vérifiée visuellement sur simulateur (iPhone 17 Pro)

Référence : Schneider 2017 (authoring), Häggström (voir `BIBLIO.md`).
Simplifications connues : repeinte intégrale du volume à chaque trait (pas
d'incrémental) ; pinceau rond en coords normalisées (légèrement elliptique à
l'écran).

**Étape 5 (scattering atmosphérique) — terminée.**
- [x] Fonction de phase Henyey-Greenstein double-lobe (avant + arrière) selon
  l'angle vue/soleil → frange argentée en contre-jour
- [x] Effet *powder* (Schneider) : assombrissement des bords fins éclairés
- [x] Approximation multi-scattering par octaves (Hillaire / Wrenninge) : la
  lumière pénètre plus profond → nuages en contre-jour qui *rayonnent*
- [x] Soleil bas en contre-jour pour l'ambiance crépusculaire
- [x] Vérifiée visuellement sur simulateur (iPhone 17 Pro)

Référence : Hillaire 2016, Patapom, Wallis, Scratchapixel (voir `BIBLIO.md`).

**Étape 6 (composition avec depth map) — terminée.**
- [x] Depth map placeholder du paysage (`makeDepthTexture`) : ciel lointain,
  relief de sol proche descendant vers l'écran
- [x] `Cloud.metal` borne le raymarch à la profondeur scène (early ray
  termination) → le nuage ne s'accumule pas derrière le relief
- [x] Soft particles : fondu de la densité à l'approche du relief (pas d'arête
  d'intersection franche)
- [x] Vérifiée visuellement sur simulateur (nuage occlus par l'horizon)

Référence : ARKit sceneDepth, Depth Anything V2, soft particles (Wolfire/Flax),
Hillaire 2016 (voir `BIBLIO.md` §4). La vraie profondeur (LiDAR / Depth Anything
via `DepthService`) remplacera la depth map placeholder à l'import photo.

**Étape 7 (demi-résolution + amortissement temporel) — terminée.**
- [x] Raymarch rendu hors écran à demi-résolution (RGBA16Float HDR), puis
  upsamplé/composité plein écran (`Composite.metal`)
- [x] Amortissement temporel : 1 cellule 2×2 sur 4 raymarchée par frame, le
  reste réutilisé depuis l'historique (ping-pong de 2 cibles)
- [x] ~1/16 du coût raymarch par frame (¼ pixels × ¼ temporel), parité visuelle
  vérifiée sur simulateur

Caméra fixe → pas de motion vectors : la « reprojection » se réduit à une
accumulation temporelle au même pixel (rafraîchissement sur 4 frames,
invisible vu la dérive lente). Une caméra mobile nécessiterait de vrais motion
vectors. Référence : Häkkinen, Nubis Evolved (voir `BIBLIO.md`).

**Étape 8 (position soleil/lune dynamique) — terminée.**
- [x] `SwiftAAAstroService` (Services) : position apparente soleil/lune en
  coordonnées horizontales (SwiftAA / Meeus), conventions converties (azimut
  depuis le Nord, longitude Est→Ouest, radians)
- [x] `CelestialPosition.worldDirection` (Domain) : mapping horizontal → monde
  (caméra face Nord : -Z = Nord, +X = Est, +Y = haut)
- [x] `CanvasView` (Feature) résout la direction et la passe au `Renderer` — le
  Rendering ne dépend pas des Services
- [x] Tests astro (Swift Testing) : midi solaire au Sud/haut, lever à l'Est,
  Soleil sous l'horizon la nuit, Lune dans les plages valides, convention monde
- [x] Vérifiée : scène par défaut Paris au crépuscule, soleil bas calculé

Référence : Hillaire 2016 & 2020, SwiftAA (voir `BIBLIO.md`). Scène fixe pour
l'instant ; le choix lieu/heure passera par les réglages. La Lune est calculée
et testée ; l'éclairage lunaire nocturne (palette froide) reste à brancher.

**Étape 9 (initialisation depuis la météo) — terminée.**
- [x] `OpenMeteoWeatherService` (Services) : météo réelle via l'API publique
  Open-Meteo (sans clé) — fallback documenté de WeatherKit
- [x] `CloudParameters` (Domain) : mapping pur météo → {biais de couverture,
  échelle d'opacité} ; dégagé/sec → fin et clairsemé, couvert/humide → plein et opaque
- [x] `CanvasView` récupère la météo en tâche async et passe les paramètres au
  `Renderer` (fallback neutre si réseau indisponible)
- [x] Tests : mapping overcast/clear/monotone (hors ligne)
- [x] Vérifiée en direct : Paris dégagé (0 % nuage) → nuage peint aminci

Référence : Hillaire 2016, Open-Meteo (voir `BIBLIO.md`).

---

## Pipeline de rendu — **complet** (étapes 1→9)

Toutes les étapes du pipeline sont implémentées et vérifiées visuellement / par
tests.

## Galerie + import photo — **terminé**

- **Navigation** : `RootView` → `GalleryView` (paysages curés + import) →
  `CanvasView(context:)`. Un `SceneContext` (scène + image + depth map) circule
  de la Feature vers le `Renderer` (qui expose `setLandscape` / `setDepthMap` :
  Rendering ne dépend toujours que du Domain).
- **Galerie curée** : `LandscapeFactory` génère des paysages *procéduraux*
  (dégradés atmosphériques) + depth map synthétique. Presets dans
  `CuratedLandscape.catalog` (lieu + heure → astro/météo).
- **Import photo** (`PhotoImporter`) : `PhotosPicker` → décodage + orientation
  EXIF, métadonnées EXIF (GPS, horodatage, cap, focale) → `Scene`, profondeur
  via `CoreMLDepthService`.
- **Profondeur réelle** : `CoreMLDepthService` (acteur) exécute Depth Anything V2
  Small F16 (`Resources/Models/`, Apache-2.0) → `DepthMap` Domain ; mappée en
  masque d'occlusion tolérant (BIBLIO §4) dans `setDepthMap`.
- **Caméra calée sur la photo** : la caméra virtuelle reproduit la vraie.
  - *Cap* (`GPSImgDirection`) → oriente le soleil relativement à la scène
    (`CelestialPosition.cameraDirection`, Nord vs Sud).
  - *Zoom* (focale 35 mm) → FOV vertical pilotant rayons + cadrage du volume.
  - *Orientation / aspect* : la photo est affichée **aspect-fit** (lettrage,
    `CanvasView`) à son ratio réel — aucune déformation paysage/portrait ; le
    FOV vertical dépend de l'orientation (24 mm vs 36 mm). Paysages curés =
    plein cadre (`displayAspect` nil).
  - *Attitude* (tangage + roulis) reconstruite depuis l'`AccelerationVector`
    (MakerNote Apple : vecteur « haut » dans le repère appareil). Tangage =
    `asin(z)` (robuste à l'orientation) ; roulis = `atan2(x, −y)` moins la
    rotation cardinale EXIF. Conventions validées sur photos iPhone réelles
    (orientations 1 et 6). Incline la direction du soleil (`cameraDirection`).
  - *Horodatage* : `OffsetTimeOriginal` (ex. "+02:00") donne l'UTC exact ;
    repli longitude sinon.
- Tests : EXIF GPS/horodatage, décalage UTC, FOV orientation/zoom, cap +
  tangage + roulis du soleil, attitude depuis de vrais `AccelerationVector`.

## Reste à faire

- **Réglages** (`Features/Settings`) : ajuster lieu/heure (les photos les
  tirent de l'EXIF ; les paysages curés ont des presets).
- **WeatherKit** comme source primaire (entitlement requis) derrière `WeatherService`.
- **LiDAR / ARKit** comme source de profondeur alternative derrière `DepthService`.
- **Éclairage lunaire** nocturne (palette froide) quand le Soleil est sous l'horizon.
- **Profilage perf sur device réel** (étape 7 vérifiée structurellement seulement).
- Pinceau : repeinte incrémentale du volume, sliders (rayon/adoucissement).
