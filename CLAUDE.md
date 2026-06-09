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

### Contrôle qualité statique

Après toute modification de code, lancer `scripts/verify.sh` : il régénère le
projet (XcodeGen) puis enchaîne **SwiftLint** (`--strict`, config
`.swiftlint.yml`), **`xcodebuild analyze`** (analyseur du compilateur) et
**Periphery** (code mort, config `.periphery.yml`). Le script échoue au premier
avertissement ; il doit rester vert. Outils à installer via Homebrew (hors du
script) : `brew install swiftlint periphery`.

### Site vitrine (`web/`)

Site statique de présentation, **HTML + CSS pur** (pas de build, pas de
framework), dans `web/` : accueil (`index.html`), politique de confidentialité
(`privacy/`) et support (`support/`) — ces deux dernières fournissent les
**URLs requises par App Store Connect**. Thème crépusculaire propre à Aether ;
l'icône de l'app est copiée en `web/icon.png`. Aperçu local :
`cd web && python3 -m http.server`.

Hébergé sur **GitHub Pages**, base canonique `https://glandais.github.io/aether/` :
- Support : `https://glandais.github.io/aether/support/`
- Confidentialité : `https://glandais.github.io/aether/privacy/`

Déploiement automatique via `.github/workflows/pages.yml` à chaque push sur
**`develop`** touchant `web/**`. Prérequis une fois : régler la source Pages du
dépôt sur **« GitHub Actions »**. Les captures réelles peuvent remplacer l'art
CSS aux emplacements `<!-- SCREENSHOT SLOT: … -->` de `index.html`.

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
| `Aether/Rendering/` | pipeline Metal, shaders, atlas de couverture / bruit 3D | Domain **uniquement** |
| `Aether/Domain/` | modèles purs (`Scene`, `CloudLayer`/`CloudGenus`, `BrushStroke`, `WeatherSnapshot`, `CelestialPosition`) | **rien** |
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

## Pipeline de rendu

Pipeline volumétrique en couches (raymarching → bruit 3D → pinceau → scattering →
demi-rés/temporel → astro → météo), plus ciel atmosphérique, mer, astres et
étoiles. **Complet et vérifié.** Les nuages vivent dans des **coquilles
sphériques concentriques** enveloppant le ciel (modèle `realtime_clouds`) : un
calque éditable = une coquille à une altitude, l'empilement crée les étages
(`CloudLayer`/`CloudGenus`, couverture peinte en carte 2D directionnelle, raymarch
concentrique). La peinture se dépose par direction du ciel ; le regard l'oriente,
il ne crée plus de domaine. Détail des étapes, choix d'implémentation et notes par
fonctionnalité : [`docs/PIPELINE.md`](docs/PIPELINE.md) ; plan et décisions du
modèle coquilles : [`docs/SHELLS.md`](docs/SHELLS.md). Références algorithmiques
(papers + code) : [`BIBLIO.md`](BIBLIO.md).

Toute évolution du rendu doit rester **visuellement vérifiable par capture sur
simulateur** (cf. « Build & vérification »).

## Conventions

- Nommage Apple-style (`UpperCamelCase` types, `lowerCamelCase` membres, pas de préfixe)
- Pas de force-unwrap en prod sauf justifié en commentaire
- Pas de singleton sauf `App` — environnement SwiftUI ou injection explicite
- Strings UI dans `Aether.xcstrings` dès le début (fr + en min., registre sobre/atmosphérique)
- Logs via `Logger` (os.log), subsystem `io.github.glandais.aether`, **pas de `print`**
- Shaders Metal commentés en **anglais** ; code Swift commenté en **français** OK
- Un commit logique par responsabilité, **jamais « WIP » ni « fixes »**
- Branche d'intégration : **`develop`** (pas de `main`) — commits et PR ciblent `develop`

## Hors scope

Import de photo personnelle (profondeur CoreML/LiDAR, EXIF, caméra calée sur la
photo) · partage social / comptes / backend · export vidéo ou animation ·
spécifique iPad au-delà de l'universal de base · localisation au-delà de fr/en ·
IAP, analytics, crash reporting.

## État d'avancement

**Distribution — App Store.** Pipeline de rendu complet plus galerie curée,
éclairage selon la scène, météo statique, heure choisie + lune, fond de ciel
atmosphérique, caméra à regard libre, **peinture en calques multi-coquilles** (une
coquille concentrique par étage : cumulus / altocumulus / cirrus, couverture peinte
par direction du ciel), mer raymarchée, soleil / lune / étoiles dessinés dans le
ciel, et persistance d'un ciel en fichier `.aether` — tout est implémenté et
vérifié. Version courante :
**`1.0.3` (build 4)**, bundle `io.github.glandais.aether` (`MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` dans `project.yml`).

- Détail du pipeline et des fonctionnalités : [`docs/PIPELINE.md`](docs/PIPELINE.md)
- Persistance d'un ciel (`.aether` : enregistrer / rouvrir à l'identique) :
  [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md)
- Distribution App Store / TestFlight (coordonnées ASC, flux release) :
  [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md)

## Reste à faire

- **Release App Store publique** (TestFlight-first pour l'instant) : captures,
  métadonnées, App Privacy, prix, soumission — détail dans
  [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md). Skills `asc-*`. URLs support /
  confidentialité fournies par le site vitrine (cf. « Site vitrine »).
- **Réglages** (`Features/Settings`) : choisir le **lieu** (l'heure est déjà
  réglable au canvas ; manque la sélection géographique manuelle).
- **Profilage perf sur device réel** : mer demi-rés confirmée à 60 ips
  (iPhone 13 Pro Max). Leviers de qualité si besoin : `SEA_ITER_FRAGMENT`,
  résolution de la passe ciel+mer (½ → ⅔), nombre de pas de la trace.
