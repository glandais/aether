# Bootstrap projet Aether

Tu vas amorcer un nouveau projet iOS Swift depuis zéro. Lis cette spec en entier avant toute action. Commence par créer `CLAUDE.md` à la racine qui consolide ce contexte pour les sessions futures.

## Nom

Aether — du grec αἰθήρ, divinité primordiale de l'air supérieur, du ciel lumineux, et cinquième élément classique (au-delà des quatre terrestres). Le nom porte directement le concept : l'utilisateur agit sur le ciel. Les textes UI et l'App Store description doivent rester dans ce registre : sobre, atmosphérique, jamais "fun" ou enfantin.

## Vision

Aether est une application iOS contemplative permettant de peindre des nuages volumétriques au-dessus d'un paysage. L'utilisateur choisit un paysage (galerie curée ou photo personnelle), peint des silhouettes de nuages dans un canvas 2D simple, et un moteur de rendu volumétrique Metal transforme ces silhouettes en nuages 3D plausibles, éclairés par la position réelle du soleil et de la lune à l'endroit et à l'heure choisis. La météo réelle à ce point/instant informe l'état initial. Expérience : contemplative, lente, satisfaisante. Pas d'éditeur 3D complexe — une poignée de sliders au maximum.

## Stack technique

- Swift 6, Xcode 16+, iOS 17+ minimum
- SwiftUI pour toute la chrome UI (gallery, palette, sliders, settings)
- MetalKit (`MTKView`) pour le canvas de rendu volumétrique
- Metal Shading Language pour raymarching, bruit 3D, composition
- WeatherKit pour la météo (fallback Open-Meteo)
- CoreLocation + PhotosUI pour photo perso + extraction EXIF GPS/timestamp
- Vision + modèle CoreML Depth Anything (converti) pour depth estimation des photos sans LiDAR
- ARKit / Scene depth pour les photos prises avec LiDAR
- SwiftAA pour soleil/lune (ou impl. interne basée formules Meeus si SwiftAA pose problème)
- Swift Concurrency (async/await, actors) — pas de Combine, pas de RxSwift
- SwiftPM uniquement, pas de CocoaPods
- Tests : XCTest + Swift Testing pour le métier (astro, weather mapping, brush→volume)

## Architecture en couches strictes

- `Aether/App/` : entry point SwiftUI, navigation racine
- `Aether/Features/` : modules SwiftUI par feature (Canvas, Gallery, PhotoImport, Settings)
- `Aether/Rendering/` : pipeline Metal, shaders, gestion des volume textures
- `Aether/Domain/` : modèles purs (`Scene`, `CloudVolume`, `BrushStroke`, `Lighting`, `WeatherSnapshot`, `CelestialPosition`) — zéro dépendance UI/réseau
- `Aether/Services/` : `WeatherService`, `AstroService`, `LocationService`, `DepthService` — protocoles + impl
- `Aether/Resources/` : assets, paysages curés, modèles CoreML

Règles de dépendance :
- Domain ne dépend de rien
- Services dépendent de Domain
- Features dépendent de Domain et Services
- Rendering dépend de Domain uniquement (pas de Service direct, on lui passe des modèles déjà résolus)
- Toute dépendance externe (WeatherKit, CoreLocation, MLModel) cachée derrière un protocole pour testabilité

## Pipeline de rendu — étapes successives, ne pas sauter

1. MVP scaffold : `MTKView` qui affiche le paysage en texture de fond + quad de test
2. Raymarching d'un seul nuage analytique (sphère de bruit) avec éclairage directionnel fixe
3. Passage à des volume textures 3D, bruit Perlin-Worley précomputé en compute shader
4. Input du pinceau → champ de densité écrit dans le volume
5. Scattering atmosphérique : Beer-Lambert + Henyey-Greenstein
6. Composition avec depth map du paysage (occlusion correcte des nuages derrière reliefs)
7. Half-res raymarching + temporal reprojection pour la perf sur device bas/moyen de gamme
8. Position soleil/lune dynamique alimentée par `AstroService`
9. Initialisation des paramètres depuis `WeatherService`

Chaque étape doit être visuellement vérifiable avant de passer à la suivante.

## Livrables de cette session de bootstrap (étape 0)

1. `CLAUDE.md` à la racine — étymologie du nom, vision condensée, stack, archi, conventions, état d'avancement (initialement "étape 1 en cours")
2. Projet Xcode `Aether.xcodeproj` initialisé avec la structure de dossiers ci-dessus, bundle id `io.github.aether` (à confirmer)
3. App SwiftUI minimale qui se lance avec un `MTKView` plein écran affichant un clear color
4. Protocoles vides des `Services/` (signatures uniquement)
5. Modèles `Domain/` (structs, sans logique)
6. Un test unitaire qui passe (n'importe lequel — valide la chaîne)
7. `.gitignore` Swift/Xcode complet, `README.md` minimal

## Conventions

- Nommage Apple-style (`UpperCamelCase` types, `lowerCamelCase` membres, pas de préfixe)
- Pas de force-unwrap en prod sauf justifié en commentaire
- Pas de singleton sauf `App` — environnement SwiftUI ou injection explicite
- Strings UI dans `Aether.xcstrings` dès le début, fr + en minimum, registre sobre/atmosphérique
- Logs via `Logger` (os.log) avec subsystem `io.github.aether`, pas de `print`
- Shaders Metal commentés en anglais, code Swift commenté en français OK
- Un commit logique par responsabilité, jamais "WIP" ou "fixes"

## Hors scope — ne fais rien là-dessus

- Partage social, comptes utilisateurs, backend
- Export vidéo / animation des nuages
- Spécifique iPad au-delà du universal de base
- Localisation au-delà de fr/en
- In-app purchase, analytics, crash reporting

## Procédure

1. Crée `CLAUDE.md` synthétisant tout ce qui précède (étymologie + vision condensée + stack + archi + conventions + état actuel)
2. Propose une arborescence détaillée de fichiers AVANT de générer du code, j'attends mon OK pour démarrer
3. Une fois validée, génère le projet en commits logiques séparés (init projet, structure, protocoles, modèles, MTKView, test). Décris chaque commit avant de le créer.
4. À chaque étape future du pipeline, mets à jour `CLAUDE.md` pour refléter l'état d'avancement

Démarre : lis la spec, pose tes questions de clarification s'il y en a, puis crée `CLAUDE.md`.