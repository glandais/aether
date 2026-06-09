# Pipeline de rendu & fonctionnalités — détail

Détail d'implémentation et historique du moteur Aether. Le résumé d'état et les
règles vivent dans [`../CLAUDE.md`](../CLAUDE.md) ; les références algorithmiques
dans [`../BIBLIO.md`](../BIBLIO.md).

## Pipeline de rendu — étapes successives

Chaque étape devait être **visuellement vérifiable** avant de passer à la suivante.

1. MVP scaffold : `MTKView` affichant le paysage en texture de fond + quad de test
2. Raymarching d'un seul nuage analytique (sphère de bruit), éclairage directionnel fixe
3. Volume textures 3D, bruit Perlin-Worley précomputé en compute shader
4. Input du pinceau → champ de densité écrit dans le volume
5. Scattering atmosphérique : Beer-Lambert + Henyey-Greenstein
6. Composition avec depth map du paysage (occlusion correcte des reliefs)
7. Half-res raymarching + temporal reprojection (perf device bas/moyen de gamme)
8. Position soleil/lune dynamique alimentée par `AstroService`
9. Initialisation des paramètres depuis la météo statique du paysage

---

## État d'avancement par étape

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

**Étape 4 (pinceau → champ de densité) — terminée, puis refondue.**
- [x] `CanvasModel` (`@Observable`) + `DragGesture` : peinture de silhouettes
  en coordonnées normalisées, bouton « Effacer » (registre sobre)
- [x] `BrushPaint.metal` : compute kernel stampant les dabs
- [x] `Cloud.metal` raymarche la silhouette peinte ; bruit Perlin-Worley en détail
- [x] Vérifiée visuellement sur simulateur (iPhone 17 Pro)

Le volume 3D peint (atlas de slabs 96×96×48 par cube) a depuis été **remplacé**
par la **couverture directionnelle** du modèle multi-coquilles (cf. « Calques
multi-coquilles »). La cible du stamp est passée d'un voxel 3D à une carte 2D
équirectangulaire par calque ; le détail vertical vient désormais de la géométrie
de coquille, plus d'une gaussienne de profondeur.

Référence : Schneider 2017 (authoring), Häggström (voir `BIBLIO.md`).
Simplifications de l'étape, **levées depuis** : repeinte intégrale à chaque trait
→ repeinte incrémentale (cf. « Pinceau ») ; pinceau elliptique à l'écran (coords
normalisées brutes) → corrigé de l'aspect (cf. « Orientation paysage »).

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
Les nuages se peignent désormais sur tout le cadre, dans toutes les directions du
ciel (couverture directionnelle des coquilles).

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

## Galerie curée — terminé

- **Navigation** : `RootView` → `GalleryView` (paysages curés) →
  `CanvasView(context:)`. Un `SceneContext` (scène + image) circule de la Feature
  vers le `Renderer` (qui expose `setLandscape` : Rendering ne dépend toujours
  que du Domain).
- **Galerie curée** : `LandscapeFactory` génère des paysages *procéduraux*
  (dégradés atmosphériques). Presets dans `CuratedLandscape.catalog`
  (lieu + heure → astro/météo). Cadrage plein écran (`displayAspect` nil), FOV
  par défaut (`Scene.defaultFieldOfView`).
- **Horodatage** : `Scene.utcOffset` approximé par la longitude du preset.

## Éclairage selon la scène — terminé

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

## Météo statique — terminé

La récupération réseau (WeatherKit / Open-Meteo) a été retirée : chaque paysage
curé porte un `WeatherSnapshot` figé dans `CuratedLandscape.catalog` (condition,
couverture, humidité, vent, température choisis pour coller à l'ambiance du
lieu). `makeContext()` en dérive les `CloudParameters` (via `CloudParameters(weather:)`,
mapping pur testé) et les transporte dans le `SceneContext`. Plus d'entitlement
`com.apple.developer.weatherkit`, plus d'attribution de source, plus de
dépendance réseau.

## Heure choisie + lune — terminé

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

## Pinceau — terminé

- **Réglages** (`CanvasView`) : bouton sobre (haut-droite) révélant rayon +
  adoucissement (sliders liés à `CanvasModel.brushRadius`/`brushSoftness`,
  appliqués aux prochains traits).
- **Repeinte incrémentale (par calque)** : `BrushPaint.metal` →
  `stamp_coverage_map` (max-combine) n'ajoute que les **nouveaux** dabs depuis la
  dernière mise à jour, dans la **tranche** d'atlas du calque concerné ;
  `clear_coverage_map` vide. `CoverageBaker` suit l'état cuit **par calque** → un
  trait qui s'allonge ne re-stampe que sa tranche. Incrémental via **ping-pong**
  de deux atlas **R8Unorm** (lit l'un, écrit l'autre, les autres tranches
  **recopiées**) — pas de `read_write`, donc format filtrable conservé. Détail de
  l'atlas et des coquilles : « Calques multi-coquilles ».
- Vérifié : panneau pinceau affiché, nuage rendu depuis la couverture peinte.

## Annuler / Rétablir — terminé

- Granularité = un trait achevé (et l'effacement, le toggle de visibilité, le
  réglage d'opacité). `CanvasModel` tient deux piles d'instantanés `[[CloudLayer]]` ;
  `beginStroke`/`clear`/`setVisible`/`snapshotForOpacity` empilent l'état d'avant
  et purgent la pile de rétablissement. Annuler un trait qui a **créé** un calque
  retire ce calque ; un trait d'extension restaure les traits du calque.
- Aucun changement du `Renderer` : la réconciliation par calque du `CoverageBaker`
  gère déjà le retrait (compte de calques/dabs ↓ → recuisson) comme l'ajout
  (→ stamp du delta).
- `CanvasView` : barre d'édition sobre (annuler / rétablir / effacer, icônes
  désactivées selon `canUndo`/`canRedo`), affichée dès qu'il y a un historique.
- Tests : `CanvasModelTests` (annuler/rétablir, purge de la pile, effacement).

## Fond de ciel dynamique (atmosphère) — câblé

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
  Voyage Feature → `Renderer` en uniformes, comme `CloudParameters`.
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
`RGBA16Float` (pas `R32Float`, cf. pièges connus dans `CLAUDE.md`).

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

## Caméra : pivoter le regard + zoom — terminé

La caméra n'est plus figée face au Nord : un bouton sobre (jumeau du pinceau,
haut-droite, icône `arrow.up.and.down.and.arrow.left.and.right`) bascule un
**mode rotation** (`CanvasModel.isRotating`). Les nuages vivant dans des
**coquilles concentriques** enveloppant le ciel (cf. « Calques multi-coquilles »),
pivoter **ou** zoomer **n'efface plus** rien : on regarde autour, et repeindre
dans une nouvelle direction **dépose de la couverture** dans cette direction.

- **Pivoter le regard** (drag à 1 doigt en mode rotation) : « saisir le ciel »
  (drag droite → ciel glisse à droite / on regarde à gauche ; drag bas → on lève
  les yeux). Lacet libre, tangage clampé (~±80°). La couverture étant indexée par
  direction, **seuls tournent** le rayon de vue (ciel, mer, nuages) et la
  direction d'éclairage soleil/lune ; le pipeline temporel est inchangé.
- **`Domain/CameraPose.swift`** (pur, testé) : base caméra → monde (lacet +
  tangage) = transposée de `CelestialPosition.cameraDirection` (monde → caméra),
  d'où la cohérence ciel ↔ éclairage. `CanvasView` calcule la base
  (`scene.heading/pitch` + lacet/tangage utilisateur) et la passe en uniformes ;
  `Background.metal` reconstruit le rayon depuis cette base (identité = ancien
  rayon Nord fixe). `SkyUniforms` **et** `CloudUniforms` portent
  `camRight/camUp/camForward` (le raymarch nuage reconstruit le même rayon pour
  échantillonner la couverture dans la direction regardée).
- **Zoom (FOV)** : pincement à 2 doigts, **disponible seulement en mode
  rotation** (mouvement de caméra). Pincer pour écarter → FOV plus étroit (zoom
  avant), clampé ~25°…100°. `fovOverride` (Feature, comme `hourOverride`) →
  `tanHalfFieldOfView` → `cameraTanHalfFov` déjà câblé (ciel + raymarch nuage).
  Les coquilles enveloppant le ciel, on zoome **dans** des nuages fixes (vrai zoom
  optique, plus d'effacement à la prise).
- *Sous l'horizon* (`Background.metal`) : teinte de sol unique (couleur `ground`
  de la palette), assombrie selon l'angle de visée (`rayDir.y`) — ancrée à la
  vue, pas à l'écran, pour qu'un tangage vers le bas n'expose pas le dégradé
  vertical baké (faux second ciel / bande claire).
- Tests : `CameraPoseTests` (base identité, orthonormalité, cas connus,
  **invariant de cohérence** avec `cameraDirection`) ; `CanvasModelTests` (clamp
  tangage, règles de création de calque — cf. section dédiée). Vérifié au
  simulateur (ciel panoramique + soleil qui se déplacent ; FOV étroit/large).

## Calques multi-coquilles — terminé

Le nuage ne vient plus d'un volume 3D peint dans des cubes ancrés au regard, mais
de **coquilles sphériques concentriques** enveloppant une « petite planète » (la
référence `realtime_clouds`). Un calque éditable = une coquille à une altitude ;
l'**empilement** des coquilles crée les étages (cumulus bas … cirrus haut). La
peinture devient une **carte de couverture 2D directionnelle** (azimut ×
élévation), pas un volume. Plan complet et décisions : [`SHELLS.md`](SHELLS.md).

- **`Domain/CloudLayer.swift`** (pur) : `{ genus, strokes, coverageBias, opacity,
  isVisible }`. Le `genus` (`CloudGenus` : cirrus / altocumulus / cumulus) fixe la
  coquille (`ShellSpec` : `inner`/`outer`/`cloudType`/`noiseScale`/`drift`).
  `CloudLayer.maxCount` (= 4) est la **source unique** de la borne : création
  (`CanvasModel`), atlas de couverture (`CoverageBaker`) et raymarch concentrique
  (`Cloud.metal`, `kMaxShells`).
- **Persistance par trait** (`Domain/BrushStroke.swift`) : chaque trait fige sa
  pose caméra (`StrokeCamera`). `stamp_coverage_map` projette une **direction de
  ciel** via cette pose, donc un trait se dépose dans la direction où le rayon
  écran pointait et **reste en place** quand on tourne/zoome — d'où « regard
  libre » sans effacement. Rien sous l'horizon (la carte s'arrête à l'élévation 0).
- **`CanvasModel`** possède `layers: [CloudLayer]`. Tout trait va dans le **calque
  actif** (`activeGenus`, créé à la volée au premier trait d'un genre). Plus de
  « nouveau cube quand le regard change » : le regard oriente la peinture, il ne
  crée plus de domaine. Undo/redo : instantanés `[[CloudLayer]]`.
- **Atlas de couverture** (`CoverageBaker`) : un atlas `texture2d_array`
  équirectangulaire (hémisphère sup., **R8Unorm** filtrable), une **tranche** par
  calque, en **ping-pong**. Réconciliation **par calque** (traits cuits + nombre
  de dabs) : un trait qui s'allonge ne re-stampe que sa tranche ; annulation /
  effacement → recuisson intégrale. `stamp_coverage_map` écrit la **tranche cible**
  et **recopie** les autres au flip ping-pong.
- **Raymarch concentrique** (`Cloud.metal`) : un rayon montant (`rd.y > 0`)
  traverse les coquilles **triées par altitude croissante** → front-to-back **sans
  tri** par pixel. La couverture, constante le long du rayon, se sample **une fois
  par coquille** dans la direction de vue. Dans chaque coquille : `height_fraction`
  × `densityHeightGradient(cloudType)` (profil vertical du genre) × couverture
  peinte × bruit Perlin-Worley 3D (indexé en `p`, `noiseScale` en coordonnées
  planète ~3·10⁻⁴). Transmittance/in-scatter **partagés** entre coquilles (un
  cirrus translucide laisse voir le cumulus dessous) ; pas borné `dmod` au ras de
  l'horizon ; auto-ombrage seul (light march borné à la coquille). Demi-rés +
  amortissement temporel **inchangés**.
- **Plomberie** : `Renderer.updateLayers` ; `MetalView`/`CanvasView` passent
  `model.layers`. `CloudUniforms` porte un tableau de `Shell` (≤ `maxCount`,
  triées) + `layerCount` ; chaque `Shell` connaît sa tranche d'atlas
  (index de cuisson, distinct du rang d'altitude).
- Tests : `CanvasModelTests` (même genre → un calque ; nouveau genre → nouveau
  calque ; retour à un genre → réutilise son calque ; undo retire le calque créé ;
  toggle de visibilité annulable) ; `CloudLayerTests` (rayons d'étages disjoints
  croissants, `noiseScale` planète, `maxCount`). Vérifié au simulateur : un ciel à
  deux étages peints (cumulus + cirrus), enregistré puis rouvert à l'identique.

## Mer raymarchée sous l'horizon — terminé

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

## Soleil & lune dessinés dans le ciel — terminé

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

## Étoiles dessinées dans le ciel — terminé

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

## God rays (rayons crépusculaires) — terminé

Quand le soleil passe derrière un nuage, des **rayons crépusculaires** subtils
jaillissent des trouées (registre sobre : doux, à peine perceptible). Technique :
**diffusion de lumière en post-process écran** (Kenny Mitchell, *GPU Gems 3*
ch. 13, cf. `BIBLIO.md`) — depuis chaque pixel, marche radiale vers la position
écran du soleil en accumulant une source masquée par la couverture nuageuse. **Auto-
régulé** : rien la nuit (couleur du soleil nulle sous l'horizon), rien sous couverture
totale (source masquée), doux par ciel clair.

- **`Rendering/Shaders/GodRays.metal`** : passe **demi-rés** (comme le ciel/nuage).
  `god_rays_fragment` retrouve la position écran du soleil en **inversant** la
  formule de rayon de `Background.metal` (mêmes `camRight/Up/Forward` + `tanHalfFov`/
  aspect → alignement au pixel près avec le disque solaire), garde `dot(soleil,
  forward) > 0` (soleil devant), puis marche (`kSamples = 48`) vers le soleil :
  source = lueur solaire gaussienne (corrigée de l'aspect → cercle écran) ×
  transmittance du nuage (`1 - alpha` de la passe nuage). Teinte par `sunDiscColor`
  (nulle sous l'horizon → night-gate gratuit), échelle `intensity`. Une seule lecture
  de texture par échantillon.
- **Plomberie** (`Renderer`) : `GodRayUniforms` (apparié main Swift ↔ `.metal`),
  cible `godRayTarget` (créée avec les cibles nuage/ciel), `godRaysPipeline`
  (rendu demi-rés HDR) + `godRaysCompositePipeline` (réutilise `composite_fragment`,
  blend **additif**). Passe 2.5 (après le ciel) écrit `godRayTarget` en lisant
  l'alpha du nuage ; composé **en dernier** au passage composite (additif, par-
  dessus tout — rayons diffusés dans l'air entre nuage et œil). Aucune dépendance
  Feature nouvelle : `cameraRight/Up/Forward`, `cameraTanHalfFov`, `skySunDirection`,
  `sunDiscColor` existaient déjà. Constantes de réglage (`godRayDensity/Decay/
  Weight/Intensity`) sur `Renderer`, sobres par défaut.
- Vérifié au simulateur (Plein midi / Sydney, nuage morcelé) : lumière chaude
  jaillissant des trouées autour du soleil, alignée sur le disque ; nuit (02:00) →
  aucun rayon (soleil sous l'horizon). 42 tests verts.

## Orientation paysage — terminé

L'app tourne librement en **portrait + paysage** (gauche/droite). Le pipeline de
rendu était déjà indépendant de l'orientation (`Renderer.draw` recalcule
`aspect = largeur/hauteur` par frame, recrée les cibles demi-rés sur
`drawableSizeWillChange`, et les shaders appliquent l'aspect à l'axe X) ;
restaient deux finitions côté Feature/pinceau :

- **Config** : `INFOPLIST_KEY_UISupportedInterfaceOrientations` (project.yml)
  liste portrait + `LandscapeLeft`/`LandscapeRight`. `UIRequiresFullScreen: YES`
  est conservé (exemption ITMS-90474 iPad + plein écran contemplatif).
- **Curseur d'heure** (`CanvasView.timeBar`) : capé à `maxWidth: 520` — sinon le
  slider collerait aux bords en paysage. Les autres contrôles sont des overlays
  alignés dans la safe area, donc se replacent seuls (vérifié : boutons dégagés
  de la Dynamic Island, barres centrées).
- **Pinceau circulaire quelle que soit l'orientation** : les dabs sont stockés en
  coords normalisées `[0,1]²` et stampés en *distance écran-proportionnelle*
  (`stamp_coverage_map` reçoit `aspect` et met `delta.x *= aspect`) → un coup de
  pinceau projette un cercle à l'écran, en portrait **comme** en paysage (corrige
  aussi l'ellipticité préexistante en portrait). Chaque trait **fige son aspect**
  dans sa `StrokeCamera` : un nuage peint en portrait reste rond une fois
  l'appareil tourné, **sans repeinte** — la pose enregistrée projette le trait au
  bon aspect quel que soit le cadrage courant.
- Vérifié au simulateur (iPhone 17 Pro) : portrait et paysage, nuage rond dans
  les deux ; build + 42 tests verts.
