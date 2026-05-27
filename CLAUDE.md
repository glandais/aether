# Aether

> Application iOS contemplative de peinture de nuages volumétriques au-dessus d'un paysage.

## Étymologie

**Aether** — du grec αἰθήρ, divinité primordiale de l'air supérieur, du ciel
lumineux, et cinquième élément classique (au-delà des quatre éléments
terrestres). Le nom porte le concept : l'utilisateur agit sur le ciel.

**Registre éditorial** (UI + App Store) : sobre, atmosphérique, contemplatif.
Jamais « fun » ni enfantin.

## Vision

L'utilisateur choisit un paysage dans une galerie curée, peint des silhouettes
de nuages dans un canvas 2D simple, et un moteur de rendu volumétrique Metal
transforme ces silhouettes en nuages 3D plausibles, éclairés par la position
réelle du soleil et de la lune à l'endroit et à l'heure choisis. Une météo
statique propre à chaque paysage curé informe l'état initial.

Expérience visée : **contemplative, lente, satisfaisante**. Pas d'éditeur 3D
complexe — une poignée de sliders au maximum.

## Stack technique

- **Swift 6**, Xcode 16+ (dev : Xcode 26.5 / Swift 6.3), **iOS 17+ minimum**
- **SwiftUI** pour toute la chrome UI (gallery, palette, sliders, settings)
- **MetalKit** (`MTKView`) pour le canvas de rendu volumétrique
- **Metal Shading Language** : raymarching, bruit 3D, composition
- **Météo statique** : chaque paysage curé porte un `WeatherSnapshot` figé (plus
  de récupération réseau / WeatherKit)
- **CoreLocation** : lieu de la scène (orientation du ciel)
- **SwiftAA** : positions soleil/lune (fallback impl. interne formules Meeus)
- **Swift Concurrency** (async/await, actors) — **pas de Combine, pas de RxSwift**
- **SwiftPM uniquement**, pas de CocoaPods
- **Tests** : XCTest + Swift Testing pour le métier (astro, météo→nuage,
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

### Build & vérification

Simulateur de référence : **iPhone 17 Pro** ; `DerivedData` dans `build/dd`.

```sh
# 1. (Re)générer le projet après tout ajout/déplacement de fichier
xcodegen generate

# 2. Compiler
xcodebuild build -project Aether.xcodeproj -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd

# 3. Tests (métier : astro, météo, éclairage…)
xcodebuild test -project Aether.xcodeproj -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd

# 4. Vérification visuelle : installer, lancer, capturer
APP="build/dd/Build/Products/Debug-iphonesimulator/Aether.app"
SIM="iPhone 17 Pro"
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" io.github.glandais.aether
xcrun simctl io "$SIM" screenshot build/shot.png
```

Le rendu Metal n'étant pas testable unitairement, **chaque étape se vérifie par
capture d'écran sur simulateur**. Les gestes ne se pilotent pas sans
interaction : pour vérifier le rendu d'un paysage/nuage donné, injecter
temporairement un `SceneContext` (ou un trait pré-peint dans `CanvasModel`),
capturer, **puis retirer le code temporaire**.

### Pièges connus

- Le Domain définit un type `Scene`, qui masque `SwiftUI.Scene`. Dans
  `AetherApp`, le `body` doit être typé `some SwiftUI.Scene` (qualifié).
- Le catalogue de strings est `Aether.xcstrings` → table **`Aether`**, pas la
  table `Localizable` par défaut. Toujours passer `tableName: "Aether"`
  (`Text("clé", tableName: "Aether")`, `String(localized:table:)`).
- **Filtrage de texture** : `R32Float` n'est **pas filtrable** sur GPU iOS
  (seulement sur Mac → le simulateur masque le bug). Toute texture
  échantillonnée en `filter::linear` doit être ≤ 16 bits (R8Unorm, RGBA16Float).
  Réserver `R32Float` aux échantillonnages `nearest` (ex. depth map).

## Architecture en couches strictes

| Couche | Rôle | Dépend de |
|---|---|---|
| `Aether/App/` | entry point SwiftUI, navigation racine | Features |
| `Aether/Features/` | modules SwiftUI par feature (Canvas, Gallery, Settings) | Domain, Services |
| `Aether/Rendering/` | pipeline Metal, shaders, volume textures | Domain **uniquement** |
| `Aether/Domain/` | modèles purs (`Scene`, `CloudVolume`, `BrushStroke`, `Lighting`, `WeatherSnapshot`, `CelestialPosition`) | **rien** |
| `Aether/Services/` | `AstroService`, `LocationService` (protocoles + impl) | Domain |
| `Aether/Resources/` | assets, paysages curés | — |

**Règles de dépendance :**
- Domain ne dépend de rien.
- Services dépendent de Domain.
- Features dépendent de Domain et Services.
- Rendering dépend de Domain uniquement (pas de Service direct ; on lui passe des
  modèles déjà résolus).
- Toute dépendance externe (CoreLocation, SwiftAA) est cachée
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
9. Initialisation des paramètres depuis la météo statique du paysage

## Conventions

- Nommage Apple-style (`UpperCamelCase` types, `lowerCamelCase` membres, pas de préfixe)
- Pas de force-unwrap en prod sauf justifié en commentaire
- Pas de singleton sauf `App` — environnement SwiftUI ou injection explicite
- Strings UI dans `Aether.xcstrings` dès le début (fr + en min., registre sobre/atmosphérique)
- Logs via `Logger` (os.log), subsystem `io.github.glandais.aether`, **pas de `print`**
- Shaders Metal commentés en **anglais** ; code Swift commenté en **français** OK
- Un commit logique par responsabilité, **jamais « WIP » ni « fixes »**

## Hors scope

Import de photo personnelle (profondeur CoreML/LiDAR, EXIF, caméra calée sur la
photo) · partage social / comptes / backend · export vidéo ou animation ·
spécifique iPad au-delà de l'universal de base · localisation au-delà de fr/en ·
IAP, analytics, crash reporting.

## État d'avancement

**Étape 0 (bootstrap) — terminée.** Projet XcodeGen, structure en couches,
modèles Domain, protocoles Services, app SwiftUI lançable, test de fumée,
signature équipe. Build + test verts.

**Étape 1 (MVP scaffold) — terminée.**
- [x] Paysage placeholder rendu en texture de fond plein écran
  (`Background.metal`, dégradé crépusculaire généré dans `Renderer`)
- [x] Quad de test composité par-dessus en alpha blending (`TestQuad.metal`)
- [x] Vérifiée visuellement sur simulateur (iPhone 17 Pro)

Le paysage est un dégradé placeholder ; la galerie curée alimente
`landscapeTexture`.

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

Référence : soft particles (Wolfire/Flax), Hillaire 2016 (voir `BIBLIO.md` §4).
La depth map synthétique des paysages curés (`LandscapeFactory`) remplace la
depth map placeholder.

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
- [x] `WeatherSnapshot` statique par paysage curé (`CuratedLandscape.catalog`) :
  plus aucune récupération réseau
- [x] `CloudParameters` (Domain) : mapping pur météo → {biais de couverture,
  échelle d'opacité} ; dégagé/sec → fin et clairsemé, couvert/humide → plein et opaque
- [x] `CuratedLandscape.makeContext()` résout les `CloudParameters` et les place
  dans le `SceneContext` ; `CanvasView` les passe au `Renderer`
- [x] Tests : mapping overcast/clear/monotone (`CloudParametersTests`)
- [x] Vérifiée : Reykjavik couvert → nuage plein ; Sydney midi dégagé → aminci

Référence : Hillaire 2016 (voir `BIBLIO.md`).

---

## Pipeline de rendu — **complet** (étapes 1→9)

Toutes les étapes du pipeline sont implémentées et vérifiées visuellement / par
tests.

## Galerie curée — **terminé**

- **Navigation** : `RootView` → `GalleryView` (paysages curés) →
  `CanvasView(context:)`. Un `SceneContext` (scène + image + depth map) circule
  de la Feature vers le `Renderer` (qui expose `setLandscape` / `setDepthMap` :
  Rendering ne dépend toujours que du Domain).
- **Galerie curée** : `LandscapeFactory` génère des paysages *procéduraux*
  (dégradés atmosphériques) + depth map synthétique (`DepthMap` Domain, mappée en
  masque d'occlusion dans `setDepthMap`). Presets dans `CuratedLandscape.catalog`
  (lieu + heure → astro/météo). Cadrage plein écran (`displayAspect` nil), FOV
  par défaut (`Scene.defaultFieldOfView`).
- **Horodatage** : `Scene.utcOffset` approximé par la longitude du preset.

## Éclairage selon la scène — **terminé**

Le nuage s'éclaire selon la scène, plus de constantes crépusculaires figées :
- `SkyLighting(sunAltitude:)` (Domain) : couleur/intensité du soleil par hauteur
  (chaud + faible à l'horizon → blanc + intense en hauteur) ; ambiance ciel
  claire et presque blanche le jour (porte la « blancheur » du corps du nuage),
  sombre la nuit, avec une lueur chaude au crépuscule/aube.
- `SkyExposure.estimate(from:)` (Feature) : luminance du paysage → point blanc.
  `CanvasView` multiplie l'éclairage par cette exposition (`SceneContext.skyExposure`)
  → le nuage est blanc et lumineux en plein jour, sombre et chaud au crépuscule,
  calé sur la photo. Résolu côté Feature, passé en uniformes au `Renderer`.
- Vérifié : photo de jour → nuage blanc (comme les vrais) ; crépuscule curé →
  nuage chaud et tamisé.

## Météo statique — **terminé**

La récupération réseau (WeatherKit / Open-Meteo) a été retirée : chaque paysage
curé porte un `WeatherSnapshot` figé dans `CuratedLandscape.catalog` (condition,
couverture, humidité, vent, température choisis pour coller à l'ambiance du
lieu). `makeContext()` en dérive les `CloudParameters` (via `CloudParameters(weather:)`,
mapping pur testé) et les transporte dans le `SceneContext`. Plus d'entitlement
`com.apple.developer.weatherkit`, plus d'attribution de source, plus de
dépendance réseau.

## Heure choisie + lune — **terminé**

- **Curseur d'heure** (`CanvasView`) : déplace l'instant de la scène (heure
  locale via `Scene.utcOffset`) → l'`AstroService` recalcule soleil **et** lune,
  le nuage se rallume en direct (dawn chaud → midi blanc → crépuscule → nuit).
  La météo (statique) ne bouge pas : seule la lumière change.
- **Éclairage lunaire** (`MoonLighting`, Domain) : froid et faible, modulé par la
  hauteur de la lune et sa fraction éclairée (`AstroService.moonIlluminatedFraction`,
  SwiftAA). `CanvasView` fond soleil↔lune selon la hauteur du soleil (bande
  crépusculaire) ; nuit sans lune → nuage sombre (correct).
- `Scene.utcOffset` : approx. longitude du preset curé.
- Tests : `MoonLighting` (phase/hauteur, teinte froide), fraction éclairée ∈ [0,1].
- Vérifié : scène curée scrutée midi → nuage blanc ; nuit → nuage sombre/froid.

## Pinceau — **terminé**

- **Réglages** (`CanvasView`) : bouton sobre (haut-droite) révélant rayon +
  adoucissement (sliders liés à `CanvasModel.brushRadius`/`brushSoftness`,
  appliqués aux prochains traits).
- **Repeinte incrémentale** : `BrushPaint.metal` → `stamp_density_volume`
  (max-combine) n'ajoute que les **nouveaux** dabs depuis la dernière mise à
  jour ; `clear_density_volume` vide. `Renderer` suit `stampedDabCount` → un
  trait qui s'allonge coûte O(nouveaux dabs), plus la repeinte intégrale de
  l'étape 4. Incrémental via **ping-pong** de deux volumes **R8Unorm** (lit
  l'un, écrit l'autre) — pas de `read_write`, donc format filtrable conservé.
- Vérifié : panneau pinceau affiché, nuage rendu depuis le volume.

## Annuler / Rétablir — **terminé**

- Granularité = un trait achevé (et l'effacement). `CanvasModel` tient deux
  piles d'instantanés `[[BrushStroke]]` ; `beginStroke`/`clear` empilent l'état
  d'avant et purgent la pile de rétablissement.
- Aucun changement du `Renderer` : sa mise à jour incrémentale gère déjà le
  retrait (compte de dabs ↓ → vide + repeinte) comme l'ajout (→ stamp de la
  queue). Les états d'historique sont des préfixes imbriqués, donc cohérents.
- `CanvasView` : barre d'édition sobre (annuler / rétablir / effacer, icônes
  désactivées selon `canUndo`/`canRedo`), affichée dès qu'il y a un historique.
- Tests : `CanvasModelTests` (annuler/rétablir, purge de la pile, effacement).

## Fond de ciel dynamique (atmosphère) — **câblé**

Modèle de diffusion atmosphérique inspiré de CesiumJS (`AtmosphereCommon.glsl`,
`computeScattering`) et Hillaire 2020, pour que le **ciel suive le soleil** au
lieu d'un dégradé figé. La galerie ne contenant plus que des paysages curés
procéduraux (l'import photo est retiré), le ciel est remplacé pour **toutes**
les scènes — plus de sky baké à segmenter.

Câblé dans le `Renderer` (passe composite) : `skyPipeline`
(`sky_background_fragment`) remplace `background_pipeline`, alimenté par
`SkyUniforms` (struct Swift à la disposition identique au `.metal`) =
`Atmosphere.earth` + **direction monde du soleil** (distincte de la lumière du
nuage, qui suit la lune la nuit) + `tanHalfFov`/aspect. `CanvasView` passe
`light.skySunDirection` (= `sun.worldDirection`) et `.earth` via `MetalView`.
Vérifié au simulateur : midi → ciel bleu, coucher → rougeoiement bas-horizon.

- **`Domain/Atmosphere.swift`** : type pur (Rayleigh/Mie : coefficients, hauteurs
  d'échelle, anisotropie `g`, rayons planète/atmosphère, hauteur d'œil,
  intensité). Défaut `Atmosphere.earth` (valeurs terrestres Bruneton/Hillaire).
  Voyage Feature → `Renderer` en uniformes, comme `Lighting`/`CloudParameters`.
- **`Rendering/Shaders/Background.metal`** : `sky_background_fragment` reconstruit
  un rayon de vue monde par pixel (même convention que `Cloud.metal` : -Z = Nord,
  +X = Est, +Y = haut, FOV via `tanHalfFov` + aspect), puis intègre la diffusion
  simple Rayleigh + Mie (marche primaire + light-march vers le soleil) →
  rougeoiement bas-soleil et halo de Mie *gratuits*, pilotés par la même
  `sunDirection` que le nuage. Sous l'horizon : dégradé paysage conservé
  (cross-fade sur `rayDir.y`). `background_fragment` (placeholder) reste l'entrée
  câblée comme repli ; `sky_background_fragment` est l'entrée active.

**Choix d'implémentation** : marche temps réel par pixel (pas de LUT). Caméra
fixe + soleil lent → le fond est cacheable et négligeable devant le raymarch
nuage (demi-rés + temporel). Passer à des LUT Hillaire-2020 seulement si le
profilage device l'exige ; toute LUT échantillonnée `filter::linear` doit être
`RGBA16Float` (pas `R32Float`, cf. pièges connus).

**Encore ouvert** :
- *Réglage* : exposition (`Renderer.skyExposure`), nombre de pas, et défauts
  `earth` sont des points de départ ; l'horizon de midi tire un peu vert/jaune,
  le crépuscule s'assombrit vite (diffusion simple, pas de multi-scattering ni
  d'afterglow). À affiner par capture.
- *Cohérence (intérêt réel, non fait)* : dériver `SkyLighting.ambient` / teinte
  soleil du **même** intégrale et multiplier le soleil reçu par le nuage par la
  transmittance-au-soleil → une seule atmosphère pilote fond, ambiance et
  éclairage du nuage, au lieu de la courbe `SkyLighting` accordée à la main.
  Les stops `skyLow`/`skyHigh` des palettes deviendraient calculés.

## Reste à faire

- **Réglages** (`Features/Settings`) : choisir le **lieu** (l'heure est déjà
  réglable au canvas ; manque la sélection géographique manuelle).
- **Ciel ↔ nuage cohérents** : brancher l'éclairage du nuage sur l'intégrale
  atmosphère (voir section ci-dessus), + réglage des constantes du ciel.
- **Profilage perf sur device réel** (étape 7 vérifiée structurellement seulement).
