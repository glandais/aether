# Aether

Application iOS contemplative de peinture de nuages volumétriques au-dessus d'un
paysage. L'utilisateur peint des silhouettes de nuages ; un moteur de rendu
volumétrique Metal les transforme en nuages 3D plausibles, éclairés par la
position réelle du soleil et de la lune à l'endroit et à l'heure choisis.

> *Aether* — du grec αἰθήρ, le ciel lumineux, cinquième élément.

## Prérequis

- Xcode 16+ (iOS 17+)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Démarrage

Le projet Xcode est généré depuis `project.yml` ; `Aether.xcodeproj` n'est pas
versionné.

```sh
xcodegen generate
open Aether.xcodeproj
```

## Documentation

Vision, architecture en couches, pipeline de rendu et conventions :
voir [`CLAUDE.md`](./CLAUDE.md).
