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

### Piège connu

Le Domain définit un type `Scene`, qui masque `SwiftUI.Scene`. Dans
`AetherApp`, le `body` doit être typé `some SwiftUI.Scene` (qualifié).

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

**Étape 1 (MVP scaffold) — scaffold en place, à finaliser.**
- [x] `MTKView` plein écran rendant un clear color (bleu crépusculaire)
- [x] `Passthrough.metal` (triangle plein écran) prêt, non encore câblé
- [ ] Paysage affiché en texture de fond
- [ ] Quad de test dessiné par-dessus (câbler `Passthrough.metal` dans le `Renderer`)

**Prochaine cible : finir l'étape 1** (texture de fond + quad), puis **étape 2** :
raymarching d'un seul nuage analytique (sphère de bruit) avec éclairage
directionnel fixe. Chaque étape doit rester visuellement vérifiable avant la
suivante.
