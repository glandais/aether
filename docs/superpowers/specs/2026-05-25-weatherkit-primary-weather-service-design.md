# WeatherKit comme source primaire derrière `WeatherService`

> Spec — 2026-05-25. Étape « Reste à faire » du pipeline : WeatherKit comme
> source météo primaire (entitlement requis), Open-Meteo en fallback, derrière
> le protocole `WeatherService` existant.

## Objectif

Faire de **WeatherKit** la source primaire de météo, avec **Open-Meteo** comme
fallback automatique, sans casser l'architecture en couches ni la testabilité.
L'attribution affichée doit refléter la **source réellement utilisée** (exigence
légale Apple pour WeatherKit ; crédit CC-BY pour Open-Meteo).

Contexte : `CloudParameters(weather:)` ne lit que `cloudCover` et `humidity` ; la
forme de `WeatherSnapshot` est donc inchangée. La scène par défaut (Paris,
2026-05-25 19:15 UTC) tombe dans la fenêtre WeatherKit (passé récent +
prévisions ~10 j) ; Open-Meteo ne sert qu'en cas d'erreur ou de date hors
fenêtre (paysages curés à dates arbitraires).

## Décisions actées

- **Composition** : service composite `FallbackWeatherService` enveloppant une
  liste ordonnée `[WeatherKit, OpenMeteo]`. Chaque implémentation reste pure ; la
  logique de fallback est unit-testable avec des fakes.
- **Attribution** : intégrée maintenant (UI minimale, registre sobre).
- **Dates hors fenêtre WeatherKit** : traitées comme un échec → fallback
  Open-Meteo (qui interroge le jour précis demandé).

## Architecture — couches préservées

| Couche | Changement |
|---|---|
| Domain | + `WeatherAttribution`, `WeatherReport` (types purs, sans framework) |
| Services | + `WeatherKitWeatherService`, `FallbackWeatherService` ; protocole `WeatherService` adapté |
| Features | `CanvasView` : service composite + UI d'attribution |
| Rendering | inchangé (consomme toujours `CloudParameters`) |

## 1. Domain

### `WeatherAttribution` (nouveau, pur)

```swift
struct WeatherAttribution: Equatable, Sendable {
    var serviceName: String        // nom propre : " Weather", "Open-Meteo"
    var legalURL: URL?             // page légale / sources de données
    var logoLightURL: URL?         // logo pour fond clair (WeatherKit)
    var logoDarkURL: URL?          // logo pour fond sombre (WeatherKit)
}
```

Pas de chaîne localisée (noms propres), pas de type de framework. Open-Meteo
fournit des constantes statiques (logos nil). WeatherKit remplit les URLs depuis
l'API Apple.

### `WeatherReport` (nouveau, pur)

```swift
struct WeatherReport: Equatable, Sendable {
    var snapshot: WeatherSnapshot
    var attribution: WeatherAttribution
}
```

Regroupe l'instantané et l'attribution de la **source qui a effectivement
répondu**.

## 2. Protocole `WeatherService` (adapté)

```swift
protocol WeatherService: Sendable {
    func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport
}
```

`snapshot(at:date:) -> WeatherSnapshot` devient `report(at:date:) ->
WeatherReport`. Churn minimal : un seul site d'appel (`CanvasView`) et
`OpenMeteoWeatherService` (qui enveloppe son `snapshot` d'une attribution
Open-Meteo statique).

## 3. Services

### `WeatherKitWeatherService: WeatherService`

- Utilise `WeatherKit.WeatherService.shared` — **qualifié** pour éviter la
  collision de nom avec notre propre protocole `WeatherService` (même piège que
  `Scene` / `SwiftUI.Scene` documenté dans CLAUDE.md).
- Requête `weather(for:including: .hourly(startDate:endDate:))` sur un intervalle
  autour de la date de scène ; sélectionne l'heure correspondante.
- Mapping → `WeatherSnapshot` :
  - `condition` : `WeatherKit.WeatherCondition` → `WeatherSnapshot.Condition`
    (fonction pure `Condition(weatherKit:)`, distingue fog/rain/snow).
  - `cloudCover` (0…1), `humidity` (0…1) directs.
  - `windSpeed` : `Measurement` → m·s⁻¹.
  - `temperature` : `Measurement` → °C.
- **Aucune heure correspondante ou toute erreur → `throw`** (le composite
  bascule alors sur le fallback).
- Attribution : depuis `WeatherKit.WeatherService.shared.attribution`
  (`legalPageURL`, `combinedMarkLightURL`, `combinedMarkDarkURL`), nom
  " Weather".

### `FallbackWeatherService: WeatherService`

- Détient une liste ordonnée `[any WeatherService]`.
- `report` essaie chaque service dans l'ordre ; retourne le premier succès ;
  rejette la dernière erreur si tous échouent.
- Logge les bascules via `Logger` (subsystem `io.github.glandais.aether`,
  catégorie `weather`). Pas de `print`.
- Seule pièce à comportement riche → unit-testable.

## 4. Feature — `CanvasView`

- `private let weather = FallbackWeatherService(services: [WeatherKitWeatherService(), OpenMeteoWeatherService()])`.
- `loadWeather()` stocke `cloudParameters` **et** `@State private var
  attribution: WeatherAttribution?` ; en cas d'échec total → `.neutral` +
  `nil`.
- **UI d'attribution minimale** : `Link` à l'échelle footnote vers `legalURL`,
  en bas à droite, registre sobre. Affiche le logo (`AsyncImage` depuis
  `logoDarkURL`/`logoLightURL`) si présent, sinon `serviceName`. Masqué tant
  qu'aucune attribution n'est résolue. Clé d'accessibilité dans la table
  `Aether` (`Aether.xcstrings`).

## 5. Entitlement / configuration projet

- Nouveau `Aether/Aether.entitlements` :
  `com.apple.developer.weatherkit = true`.
- `project.yml` : `CODE_SIGN_ENTITLEMENTS: Aether/Aether.entitlements` sur la
  cible `Aether` ; régénération via `xcodegen generate`
  (`Aether.xcodeproj` est git-ignoré).
- **Prérequis manuel (hors de portée de l'automatisation)** : l'App ID
  `io.github.glandais.aether` doit avoir la capability/service **WeatherKit**
  activée dans le portail Apple Developer ; la propagation peut prendre ~30 min.
  Avant cela, le projet compile mais l'appel live échoue → fallback silencieux
  sur Open-Meteo. À documenter dans la section « État d'avancement » de
  `CLAUDE.md`.

## 6. Tests (Swift Testing)

- `FallbackWeatherServiceTests` (fakes en mémoire) :
  - primaire réussit → retourne le rapport primaire ;
  - primaire échoue, secondaire réussit → retourne le rapport secondaire
    (assertion : `attribution` correspond à la source qui a servi) ;
  - tous échouent → rejette l'erreur.
- Mapping pur `WeatherSnapshot.Condition(weatherKit:)` — seule logique touchant
  WeatherKit testable hors ligne.
- L'appel WeatherKit live **n'est pas** unit-testé (entitlement + réseau
  requis) → vérifié manuellement sur simulateur.

## Hors scope (YAGNI)

Écran de réglages / sélecteur lieu-heure ; cache disque de l'attribution ;
alertes WeatherKit / précipitations minute par minute ; gestion du rate-limit
au-delà du fallback.

## Vérification

- `xcodegen generate` + build de la cible `Aether` (simulateur) vert.
- Tests `AetherTests` verts.
- Vérification visuelle simulateur : nuage initialisé depuis la météo, lien
  d'attribution affiché reflétant la source utilisée.
