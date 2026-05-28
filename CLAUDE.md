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
  Réserver `R32Float` aux échantillonnages `nearest`.

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

**Distribution — App Store.** Pipeline de rendu complet (étapes 1→9) plus
galerie curée, éclairage selon la scène, météo statique, heure choisie + lune,
fond de ciel atmosphérique, caméra à regard libre, mer raymarchée, et soleil /
lune / étoiles dessinés dans le ciel — tout est implémenté et vérifié. Version
courante : **`1.0.1` (build 2)**, bundle `io.github.glandais.aether`
(`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` dans `project.yml`). Détail des
étapes ci-dessous.

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

**Étape 6 (composition avec depth map) — implémentée puis retirée.**

Avait été faite (occlusion du nuage par une depth map synthétique du paysage,
early ray termination + soft particles). **Retirée depuis** : les paysages curés
étant des dégradés atmosphériques abstraits sans relief réel, la depth map ne
faisait que couper les nuages le long d'une ligne d'horizon arbitraire. Tout le
pipeline de profondeur (`DepthMap` Domain, `LandscapeFactory.depthMap`,
`Renderer.setDepthMap`/`makeDepthTexture`, échantillonnage `sceneDepth` +
soft-particles dans `Cloud.metal`, champ `SceneContext.depthMap`) a été supprimé.
Les nuages se peignent désormais sur tout le cadre. Le raymarch n'est plus borné
que par l'AABB du volume.

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
  `CanvasView(context:)`. Un `SceneContext` (scène + image) circule de la Feature
  vers le `Renderer` (qui expose `setLandscape` : Rendering ne dépend toujours
  que du Domain).
- **Galerie curée** : `LandscapeFactory` génère des paysages *procéduraux*
  (dégradés atmosphériques). Presets dans `CuratedLandscape.catalog`
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
  (cross-fade sur `rayDir.y`), assombri par le facteur d'éclairement de sol
  (`camera.z`). `background_vertex` (triangle plein écran) est partagé ;
  l'ancien `background_fragment` placeholder a été retiré.

**Choix d'implémentation** : marche temps réel par pixel (pas de LUT). Caméra
fixe + soleil lent → le fond est cacheable et négligeable devant le raymarch
nuage (demi-rés + temporel). Passer à des LUT Hillaire-2020 seulement si le
profilage device l'exige ; toute LUT échantillonnée `filter::linear` doit être
`RGBA16Float` (pas `R32Float`, cf. pièges connus).

**Cohérence ciel ↔ nuage — fait.** Le nuage est éclairé par la **même**
atmosphère que le fond (port CPU de l'intégrale dans `Atmosphere`, ~2 marches
par frame) :
- *Soleil du nuage* = `Atmosphere.sunTransmittance(sunDirection:)` × échelle →
  chaud quand le soleil est bas (comme le ciel), blanc haut, nul sous l'horizon.
- *Ambiance du nuage* = `Atmosphere.skyRadiance(viewDirection: zénith,…)`,
  désaturée (`ambientSaturation`) pour ne pas griser le corps du nuage.
- Fondu vers la `MoonLighting` la nuit (via `sunWeight`). `CanvasView` calcule
  tout ; les échelles `cloudSunStrength`/`cloudAmbientStrength` ne font que caler
  la luminosité (la teinte vient de la physique).
- Vérifié : midi → nuage à crête blanche / base gris-bleu (cumulus réaliste) ;
  soleil bas → nuage doré, cohérent avec le ciel ; nuit → sombre/lunaire.
- Tests : `AtmosphereTests` (transmittance chaude/sombre/occlusion, radiance ciel).

**Encore ouvert (réglage)** : exposition (`Renderer.skyExposure`), nb de pas,
échelles nuage et défauts `earth` sont des points de départ ; l'horizon de midi
tire un peu vert/jaune, le crépuscule s'assombrit vite (diffusion simple, pas de
multi-scattering ni d'afterglow). `SkyLighting` n'est plus utilisé pour le nuage
(seul son `smoothstep` sert encore de `sunWeight`) ; les stops `skyLow`/`skyHigh`
des palettes pourraient devenir calculés. À affiner par capture.

## Caméra : pivoter le regard + zoom — **terminé**

La caméra n'est plus figée face au Nord : un bouton sobre (jumeau du pinceau,
haut-droite, icône `arrow.up.and.down.and.arrow.left.and.right`) bascule un
**mode rotation** (`CanvasModel.isRotating`). Tout mouvement de caméra (rotation
**ou** zoom) **efface les nuages à la prise** (`CanvasModel.clearForCameraChange`,
non annulable) : on reframe un ciel vierge, puis on repeint.

- **Pivoter le regard** (drag à 1 doigt en mode rotation) : « saisir le ciel »
  (drag droite → ciel glisse à droite / on regarde à gauche ; drag bas → on lève
  les yeux). Lacet libre, tangage clampé (~±80°). Le volume de nuage étant
  relatif à la caméra (peinture en coords écran, effacée à la rotation), **seuls
  tournent** le rayon de vue du ciel et la direction d'éclairage soleil/lune ; le
  raymarch du nuage, le volume et le pipeline temporel sont inchangés.
- **`Domain/CameraPose.swift`** (pur, testé) : base caméra → monde (lacet +
  tangage) = transposée de `CelestialPosition.cameraDirection` (monde → caméra),
  d'où la cohérence ciel ↔ éclairage. `CanvasView` calcule la base
  (`scene.heading/pitch` + lacet/tangage utilisateur) et la passe en uniformes ;
  `Background.metal` reconstruit le rayon depuis cette base (identité = ancien
  rayon Nord fixe). `SkyUniforms` étendu de `camRight/camUp/camForward`
  (`CloudUniforms` inchangé).
- **Zoom (FOV)** : pincement à 2 doigts, **disponible seulement en mode
  rotation** (mouvement de caméra). Pincer pour écarter → FOV plus étroit (zoom
  avant), clampé ~25°…100°. `fovOverride` (Feature, comme `hourOverride`) →
  `tanHalfFieldOfView` → `cameraTanHalfFov` déjà câblé (ciel + cadrage du volume).
  Le volume étant cadré sur le frustum courant, le zoom reframe le ciel et le
  détail du bruit ; ce n'est pas un zoom optique qui agrandit un nuage déjà peint
  (sans objet : les nuages sont effacés à la prise).
- *Sous l'horizon* (`Background.metal`) : teinte de sol unique (couleur `ground`
  de la palette), assombrie selon l'angle de visée (`rayDir.y`) — ancrée à la
  vue, pas à l'écran, pour qu'un tangage vers le bas n'expose pas le dégradé
  vertical baké (faux second ciel / bande claire).
- Tests : `CameraPoseTests` (base identité, orthonormalité, cas connus,
  **invariant de cohérence** avec `cameraDirection`) ; `CanvasModelTests`
  (`clearForCameraChange`, clamp tangage). Vérifié au simulateur (ciel
  panoramique + soleil qui se déplacent ; FOV étroit/large).

## Mer raymarchée sous l'horizon — **terminé**

Certains paysages curés portent une **mer animée** rendue sous l'horizon
(raymarching de hauteur, technique « Seascape » d'Alexander Alekseev / TDM,
Shadertoy `Ms2SD1`, portée en MSL — attribution conservée en en-tête de
`Background.metal`). La caméra à regard libre la traverse naturellement
(pivoter/baisser les yeux → on voit la houle).

- **`Domain/SeaSurface.swift`** (pur) : `enabled`, `level` (hauteur de l'œil
  au-dessus du plan de mer, m), `height`/`choppy`/`frequency`/`speed` (houle),
  `baseColor`/`waterColor`. `.none` (terrestre) / `.calm` (registre contemplatif :
  `choppy`/`speed` adoucis vs les défauts d'origine, œil à 3 m). Voyage
  `CuratedLandscape` → `SceneContext` → `CanvasView` → `Renderer` en uniformes
  (`SkyUniforms` étendu), comme `Atmosphere`. Activée sur Aube/Heure bleue/Plein
  midi du catalogue.
- **`Background.metal`** : la branche **sous-horizon** de `sky_background_fragment`
  rend la mer (sinon la teinte de sol). Trace de hauteur sur le **rayon monde** de
  la caméra libre (œil local en `(0, level, 0)`, surface moyenne en `y≈0`), normale
  par différences finies, ombrage Fresnel + reflet de ciel + base + **glint
  soleil** (vrai `sunDir`). La houle reste **world-locked** quand on balaye.
  - *Cohérence ciel ↔ mer* : le reflet ne refait **pas** d'intégrale par pixel ;
    c'est un **dégradé zénith↔horizon** dont les deux couleurs sont les intégrales
    CPU de `Atmosphere` (déjà calculées pour l'ambiance du nuage), passées en
    uniformes (`skyZenith`/`skyHorizon`). Chaud quand le soleil est bas, bleu haut.
  - *Horizon propre* : l'eau lointaine se **dissout** vers le reflet d'horizon
    (`smoothstep` sur la distance) → masque l'aliasing/spikes de la trace au ras
    de l'horizon. Crêtes : tint clampé ≥ 0 (sinon stries noires dans les creux).
  - *Nuit* : la partie solaire est assombrie par le facteur de sol ; un **clair de
    lune** (moonglade spéculaire + voile, `MoonLighting` + direction monde de la
    lune, *night-gated*) survit à cet assombrissement → reflet lunaire quand la
    lune est levée et se reflète dans l'eau visible (lune haute ⇒ il faut baisser
    les yeux, physiquement correct).
- **Perf — demi-résolution.** Le raymarch de mer est coûteux. La passe
  **ciel + mer** est désormais rendue **hors écran à demi-résolution** (HDR
  `cloudColorFormat`, `skyTarget` créé avec les cibles nuage), puis upsamplée
  (bilinéaire) et composée « over » au passage composite — comme le nuage. La
  composition empile : ciel+mer upsamplé, puis nuage upsamplé. ~4× sur le coût
  fragment dominant : **60 ips sur device** (iPhone 13 Pro Max) — vs ~5 ips en
  plein écran avec intégrales par pixel, ~13 ips après réduction des intégrales,
  60 ips une fois la passe en demi-rés.
- **FPS** : `Renderer.draw` journalise les images/s (~1 s, os.log, subsystem
  `io.github.glandais.aether`, catégorie `Renderer`) — `log stream --level info`.

## Soleil & lune dessinés dans le ciel — **terminé**

Le ciel dessine désormais les deux astres, dans la passe de fond
(`Background.metal`, avant la composition du nuage → occlus par les nuages,
et suivant le regard/zoom *gratuitement* puisque le rayon de vue est en monde).

- **Soleil** : cœur brillant + halo de *bloom* doux (`sunDisc`). La couleur vient
  de la **transmittance atmosphérique** déjà calculée pour le nuage
  (`Atmosphere.sunTransmittance`) → chaude/rougie quand le soleil est bas, nulle
  sous l'horizon (le disque s'éteint seul ; le *ground mix* clippe tout débord).
- **Lune** : disque **phasé** (croissant/gibbeuse) dont le côté éclairé et
  l'orientation découlent des **seules** directions apparentes du Soleil et de la
  Lune (aucune donnée astro supplémentaire) ; terminateur doux, *earthshine*
  ténue sur la face sombre, léger *mottling* de surface (`moonDisc`).
- **Halo lunaire** : comme le soleil, la lune *éclaire* le ciel — halo froid
  analytique (lobe avant `pow(cosToMoon,…)`) + lift bleuté ténu, teinté par
  `moonGlint` (donc échelonné par phase/altitude), *night-gated*. Choix d'un halo
  analytique plutôt que d'une 2ᵉ intégrale atmosphérique vers la lune : cette
  dernière ajoutait une bande chaude rasante à l'horizon (fausse aube nocturne).
- **Taille constante avec l'heure** (décidé) : le diamètre apparent réel varie à
  peine sur une journée, le « gros soleil à l'horizon » est une illusion
  perceptive non reproductible, et l'aplatissement par réfraction a été écarté.
  Disques légèrement agrandis (~2× le vrai 0.5°) pour une présence lisible —
  rayons/luminosités sont des constantes réglables (`Renderer.sunAngularRadius`/
  `moonAngularRadius`, `CanvasView.sunDiscBrightness`/`moonDiscBrightness`).
- **`Domain/MoonPhase.swift`** (pur, testé) : `brightLimbDirection` (projection du
  Soleil dans le plan du disque, repli orthogonal fini si colinéaire → pas de NaN)
  et `surfaceLit` (normale de l'hémisphère visible → `dot(n, soleil)`). Le shader
  `moonDisc` **reproduit** cette formule (couple CPU/GPU comme `Atmosphere`).
- **Plomberie** : `SkyUniforms` (apparié à la main Swift ↔ `.metal`) gagne 3 champs
  `float4` *appendus* en fin de struct (rayons des disques, couleurs soleil/lune) ;
  la position de la lune **réutilise** le champ `moonDirection` déjà introduit par
  la mer. `Renderer.updateDiscs(sunColor:moonColor:)` ; `MetalView`/`CanvasView`
  transmettent les deux couleurs (le Rendering ne dépend toujours que du Domain).
  Les disques sont composés dans `skyColor` (display-referred, après tonemap) avant
  le mix sol/mer, donc occlus par la mer/le sol sous l'horizon comme par les nuages.
- Tests : `MoonPhaseTests` (nouvelle/pleine/quartier, limbe vers le Soleil, cas
  dégénéré sans NaN). Vérifié au simulateur : midi → disque solaire blanc + halo ;
  coucher → soleil bas rougi ; nuit → lune gibbeuse (~75 %) avec terminateur,
  *mottling* et *earthshine*.

## Étoiles dessinées dans le ciel — **terminé**

Le ciel dessine les étoiles du **Yale Bright Star Catalog** (BSC5, ~9 110 étoiles).
Contrairement au soleil et à la lune, ce sont de **purs points passifs** : ils
**n'éclairent rien** (pas de halo, pas de contribution atmosphère/nuage). Ils
sont *night-gated* (s'allument quand le ciel s'assombrit), **occlus par les
nuages**, et **world-locked** (suivent le regard/zoom comme le reste du ciel).

- **Donnée** : `Aether/Resources/bsc5.bin` (binaire compact little-endian, 16 o/étoile :
  `ra_rad, dec_rad, vmag, bv`), généré depuis la source ADC/Harvard par
  `scripts/build_star_catalog.py` (provenance/attribution → `BIBLIO.md`).
  Embarqué via `sources: [path: Aether]` (pas de changement `project.yml`).
- **`Domain/StarCatalog.swift`** (pur, testé) : `load()` (décodage binaire),
  `localSiderealTime` (GMST de Meeus depuis la date julienne + longitude Est),
  `visibleStars` (équatorial J2000 → horizontal via angle horaire + latitude,
  réutilise `CelestialPosition.worldDirection` ; émet jusqu'à ~−1° d'altitude, le
  fondu fin se fait au shader). Aucune dépendance Services ; précession/nutation/
  réfraction négligées (sous l'échelle d'un point).
- **Feature** (`CanvasView`) : catalogue chargé une fois (statique). Les directions
  monde sont recalculées **hors `body`** via `.task(id: StarKey)` (lieu + tranche
  de temps ~60 s) — **jamais** par frame de rotation/zoom (qui ne changent que la
  base caméra, appliquée côté GPU). Un `starRevision` croissant fait que le
  `Renderer` ne reconstruit le buffer que sur changement réel.
- **Rendering** : `Renderer.updateStars(_:revision:)` ; les points sont dessinés
  dans la **passe composite plein écran**, **entre** l'upsample du ciel et le
  nuage (blend **additif**), donc au-dessus du ciel et occlus par le nuage qui
  suit. `Stars.metal` (`star_vertex`/`star_fragment`) : projection du `worldDirection`
  par inversion du rayon de `Background.metal` (mêmes `camRight/Up/Forward` +
  `tanHalfFov`/aspect → coïncidence au pixel près), rejet par le clip si derrière
  la caméra ; magnitude → luminosité (flux de Pogson compressé en √) et taille du
  *point sprite* (mise à l'échelle douce du zoom) ; **teinte réelle par indice
  B-V** (bleu → blanc → orangé) ; **scintillement subtil** (phase par étoile) ;
  fondu d'horizon (`smoothstep` sur `direction.y`) ; *night-gate* (`nightWeight`).
- Tests : `StarCatalogTests` (pôle céleste → altitude = latitude ; équateur au
  méridien → Sud ; sous l'horizon écarté ; LST borné et ~15°/h ; décodage binaire).
  Vérifié au simulateur (nuit Paris) : champ d'étoiles colorées au-dessus de
  l'horizon, scintillant ; occultées par une bande de nuage peinte ; absentes le jour.

## Reste à faire

- **Réglages** (`Features/Settings`) : choisir le **lieu** (l'heure est déjà
  réglable au canvas ; manque la sélection géographique manuelle).
- **Profilage perf sur device réel** : mer demi-rés confirmée à 60 ips
  (iPhone 13 Pro Max). Leviers de qualité si besoin : `SEA_ITER_FRAGMENT`,
  résolution de la passe ciel+mer (½ → ⅔), nombre de pas de la trace.
