# Aether

Application iOS contemplative de peinture de nuages volumétriques au-dessus d'un
paysage. L'utilisateur choisit un paysage dans une galerie curée, peint des
silhouettes de nuages dans un canvas 2D simple, et un moteur de rendu
volumétrique Metal les transforme en nuages 3D plausibles — éclairés par la
position réelle du soleil et de la lune à l'endroit et à l'heure choisis.

> *Aether* — du grec αἰθήρ, le ciel lumineux, cinquième élément.

Expérience visée : **contemplative, lente, satisfaisante**. Pas d'éditeur 3D —
une poignée de gestes et de sliders.

## L'expérience

- **Peinture de nuages** : silhouettes peintes au doigt → champ de densité 3D
  raymarché (Perlin-Worley, Beer-Lambert, Henyey-Greenstein, multi-scattering),
  pinceau réglable (rayon / adoucissement), annuler / rétablir.
- **Ciel physique** : fond atmosphérique (Rayleigh + Mie) qui suit le soleil ;
  soleil, lune **phasée** et étoiles (Bright Star Catalog) dessinés dans le ciel,
  occlus par les nuages.
- **Lumière réelle** : curseur d'heure → l'astro recalcule soleil et lune en
  direct (aube chaude → midi blanc → crépuscule → nuit lunaire). Météo statique
  par paysage qui informe l'état initial du nuage.
- **Mer raymarchée** sous l'horizon sur certains paysages, avec reflet de ciel,
  glint solaire et clair de lune.
- **Regard libre** : pivoter la vue (1 doigt) et zoomer (pincement) ; le ciel et
  l'éclairage suivent.
- **Enregistrer un ciel** : sauvegarder l'état complet (paysage, nuages, instant,
  regard) dans un fichier `.aether` autonome, rouvrir plus tard à l'identique.

## Galerie curée

Quatre paysages procéduraux, chacun avec son lieu, son heure et sa météo :
**Crépuscule** (Paris), **Aube** (Kyoto), **Heure bleue** (Reykjavik),
**Plein midi** (Sydney).

## Prérequis

- Xcode 16+ (iOS 17+)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Démarrage

Le projet Xcode est généré depuis `project.yml` (source de vérité) ;
`Aether.xcodeproj` n'est pas versionné. Ajouter un fichier = créer le fichier,
puis régénérer.

```sh
# Générer le projet (après tout ajout/déplacement de fichier)
xcodegen generate
open Aether.xcodeproj

# Compiler en ligne de commande
xcodebuild build -project Aether.xcodeproj -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd

# Tests métier (astro, météo→nuage, caméra, phases de lune, étoiles…)
xcodebuild test -project Aether.xcodeproj -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd
```

Le rendu Metal n'étant pas testable unitairement, chaque étape se vérifie par
capture d'écran sur simulateur (iPhone 17 Pro de référence).

## Stack

Swift 6 · SwiftUI · MetalKit (raymarching MSL) · SwiftAA (positions soleil/lune)
· CoreLocation · Swift Concurrency · SwiftPM. Pipeline de rendu complet
(étapes 1→9), pas de dépendance réseau.

## Documentation

Vision, architecture en couches, pipeline de rendu, conventions et état
d'avancement : [`CLAUDE.md`](./CLAUDE.md). Pipeline de rendu détaillé :
[`docs/PIPELINE.md`](./docs/PIPELINE.md). Persistance d'un ciel (`.aether`) :
[`docs/PERSISTENCE.md`](./docs/PERSISTENCE.md). Références algorithmiques (papers
+ code) : [`BIBLIO.md`](./BIBLIO.md).
</content>
</invoke>
