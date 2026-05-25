# WeatherKit Primary WeatherService Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make WeatherKit the primary weather source behind the existing `WeatherService` protocol, with Open-Meteo as an automatic fallback, and surface source-appropriate attribution.

**Architecture:** A `FallbackWeatherService` composite tries `[WeatherKitWeatherService, OpenMeteoWeatherService]` in order. The protocol returns a `WeatherReport` (snapshot + attribution) so the UI credits the source that actually served the data. Domain stays framework-free; WeatherKit is confined to its Services file.

**Tech Stack:** Swift 6, WeatherKit, CoreLocation, SwiftUI, Swift Testing, XcodeGen.

---

## Spec

`docs/superpowers/specs/2026-05-25-weatherkit-primary-weather-service-design.md`

## File Structure

- Create `Aether/Domain/WeatherAttribution.swift` — pure attribution value (name + URLs).
- Create `Aether/Domain/WeatherReport.swift` — bundles `WeatherSnapshot` + `WeatherAttribution`.
- Modify `Aether/Services/WeatherService.swift` — protocol returns `WeatherReport`.
- Modify `Aether/Services/OpenMeteoWeatherService.swift` — returns `WeatherReport` with static Open-Meteo attribution.
- Create `Aether/Services/FallbackWeatherService.swift` — ordered composite + logging.
- Create `Aether/Services/WeatherKitWeatherService.swift` — WeatherKit adapter + pure condition mapping.
- Create `Aether/Aether.entitlements` — `com.apple.developer.weatherkit`.
- Modify `project.yml` — `CODE_SIGN_ENTITLEMENTS`.
- Modify `Aether/Features/Canvas/CanvasView.swift` — composite wiring + attribution UI.
- Modify `Aether/Resources/Aether.xcstrings` — attribution accessibility label.
- Modify `CLAUDE.md` — "État d'avancement".
- Create `Tests/AetherTests/FallbackWeatherServiceTests.swift`.
- Create `Tests/AetherTests/WeatherKitMappingTests.swift`.

## Conventions for this plan

- New files under `Aether/` are auto-globbed by XcodeGen (`sources: - path: Aether`), but `Aether.xcodeproj` is git-ignored and regenerated. **After adding or removing any file, run `xcodegen generate` before building.**
- Build/test command (simulator `iPhone 17 Pro` is booted; adjust the name if yours differs):

  ```bash
  xcodebuild test -scheme Aether \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -quiet
  ```
- Swift code comments in French OK; Metal/none here. Logs via `Logger`, never `print`.

---

### Task 1: Domain types + protocol refactor

Introduces `WeatherAttribution` / `WeatherReport`, switches the protocol to return a report, and updates the two existing call sites so the build stays green. Pure refactor — verified by the existing test suite.

**Files:**
- Create: `Aether/Domain/WeatherAttribution.swift`
- Create: `Aether/Domain/WeatherReport.swift`
- Modify: `Aether/Services/WeatherService.swift`
- Modify: `Aether/Services/OpenMeteoWeatherService.swift:18-41`
- Modify: `Aether/Features/Canvas/CanvasView.swift:52-60`

- [ ] **Step 1: Create `WeatherAttribution`**

```swift
import Foundation

/// Attribution de la source météo — affichée telle quelle (noms propres, pas de
/// localisation). Pur : pas de dépendance framework. Open-Meteo fournit des
/// constantes ; WeatherKit remplit les URLs depuis l'API Apple.
struct WeatherAttribution: Equatable, Sendable {
    var serviceName: String
    var legalURL: URL?
    var logoLightURL: URL?
    var logoDarkURL: URL?

    /// Attribution statique d'Open-Meteo (crédit CC-BY, pas de logo).
    static let openMeteo = WeatherAttribution(
        serviceName: "Open-Meteo",
        legalURL: URL(string: "https://open-meteo.com"),
        logoLightURL: nil,
        logoDarkURL: nil
    )
}
```

- [ ] **Step 2: Create `WeatherReport`**

```swift
/// Résultat d'une requête météo : l'instantané et l'attribution de la source
/// qui a effectivement répondu.
struct WeatherReport: Equatable, Sendable {
    var snapshot: WeatherSnapshot
    var attribution: WeatherAttribution
}
```

- [ ] **Step 3: Update the protocol**

Replace the body of `Aether/Services/WeatherService.swift` with:

```swift
import Foundation

/// Fournit l'état météo à un point/instant. Source primaire WeatherKit
/// (entitlement requis), fallback Open-Meteo — voir `FallbackWeatherService`.
protocol WeatherService: Sendable {
    func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport
}
```

- [ ] **Step 4: Update `OpenMeteoWeatherService`**

Rename the method and wrap the snapshot. Change the signature at line 18 from
`func snapshot(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherSnapshot {`
to `func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport {`,
and change the final `return` (line 39-40) from:

```swift
        let payload = try JSONDecoder().decode(Response.self, from: data)
        return try payload.snapshot(forHourMatching: date)
```

to:

```swift
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let snapshot = try payload.snapshot(forHourMatching: date)
        return WeatherReport(snapshot: snapshot, attribution: .openMeteo)
```

Also update the doc comment at the top to drop "(à brancher plus tard)" since it is now branched.

- [ ] **Step 5: Update the `CanvasView` call site**

In `loadWeather()` (lines 52-60), change:

```swift
            let snapshot = try await weather.snapshot(
                at: Self.defaultScene.coordinate, date: Self.defaultScene.date)
            cloudParameters = CloudParameters(weather: snapshot)
```

to:

```swift
            let report = try await weather.report(
                at: Self.defaultScene.coordinate, date: Self.defaultScene.date)
            cloudParameters = CloudParameters(weather: report.snapshot)
```

(`weather` stays `OpenMeteoWeatherService()` for now; the composite swap is Task 5.)

- [ ] **Step 6: Regenerate and build/test**

Run:
```bash
xcodegen generate && xcodebuild test -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```
Expected: BUILD SUCCEEDED, all existing tests pass (CloudParameters/Astro/DomainSmoke). The refactor is behavior-preserving.

- [ ] **Step 7: Commit**

```bash
git add Aether/Domain/WeatherAttribution.swift Aether/Domain/WeatherReport.swift \
        Aether/Services/WeatherService.swift Aether/Services/OpenMeteoWeatherService.swift \
        Aether/Features/Canvas/CanvasView.swift
git commit -m "refactor(weather): WeatherService renvoie un WeatherReport (snapshot + attribution)"
```

---

### Task 2: `FallbackWeatherService` (TDD)

Ordered composite: first success wins, last error rethrown if all fail. This is the only behavior-rich piece — test-driven with in-memory stubs.

**Files:**
- Test: `Tests/AetherTests/FallbackWeatherServiceTests.swift`
- Create: `Aether/Services/FallbackWeatherService.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AetherTests/FallbackWeatherServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import Aether

/// Valide la logique de bascule du composite, hors ligne (stubs en mémoire).
struct FallbackWeatherServiceTests {
    /// Stub renvoyant un résultat fixe sans toucher au réseau.
    private struct StubWeatherService: WeatherService {
        let result: Result<WeatherReport, any Error>
        func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport {
            try result.get()
        }
    }

    private enum StubError: Error { case unavailable }

    private static let coordinate = GeoCoordinate(latitude: 48.85, longitude: 2.35)

    private static func report(named name: String) -> WeatherReport {
        WeatherReport(
            snapshot: WeatherSnapshot(
                condition: .cloudy, cloudCover: 0.5, humidity: 0.6,
                windSpeed: 3, temperature: 14),
            attribution: WeatherAttribution(serviceName: name, legalURL: nil,
                                            logoLightURL: nil, logoDarkURL: nil))
    }

    @Test("Le service primaire qui réussit est utilisé tel quel")
    func primarySucceeds() async throws {
        let primary = StubWeatherService(result: .success(Self.report(named: "Primary")))
        let secondary = StubWeatherService(result: .success(Self.report(named: "Secondary")))
        let service = FallbackWeatherService(services: [primary, secondary])

        let report = try await service.report(at: Self.coordinate, date: Date())
        #expect(report.attribution.serviceName == "Primary")
    }

    @Test("Si le primaire échoue, le secondaire sert (attribution de la source réelle)")
    func fallsBackToSecondary() async throws {
        let primary = StubWeatherService(result: .failure(StubError.unavailable))
        let secondary = StubWeatherService(result: .success(Self.report(named: "Secondary")))
        let service = FallbackWeatherService(services: [primary, secondary])

        let report = try await service.report(at: Self.coordinate, date: Date())
        #expect(report.attribution.serviceName == "Secondary")
    }

    @Test("Si tous échouent, la dernière erreur est propagée")
    func allFailRethrows() async {
        let primary = StubWeatherService(result: .failure(StubError.unavailable))
        let secondary = StubWeatherService(result: .failure(StubError.unavailable))
        let service = FallbackWeatherService(services: [primary, secondary])

        await #expect(throws: StubError.self) {
            _ = try await service.report(at: Self.coordinate, date: Date())
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodegen generate && xcodebuild test -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AetherTests/FallbackWeatherServiceTests -quiet
```
Expected: compile failure — `cannot find 'FallbackWeatherService' in scope`.

- [ ] **Step 3: Implement `FallbackWeatherService`**

Create `Aether/Services/FallbackWeatherService.swift`:

```swift
import Foundation
import os

/// Compose plusieurs `WeatherService` en cascade : retourne le premier succès,
/// rejette la dernière erreur si tous échouent. Permet WeatherKit primaire +
/// Open-Meteo fallback derrière une seule façade.
struct FallbackWeatherService: WeatherService {
    enum CompositeError: Error { case noServices }

    private let services: [any WeatherService]
    private let log = Logger(subsystem: "io.github.glandais.aether", category: "weather")

    init(services: [any WeatherService]) {
        self.services = services
    }

    func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport {
        var lastError: (any Error)?
        for (index, service) in services.enumerated() {
            do {
                return try await service.report(at: coordinate, date: date)
            } catch {
                lastError = error
                log.notice("Source météo \(index, privacy: .public) indisponible, bascule sur la suivante.")
            }
        }
        throw lastError ?? CompositeError.noServices
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AetherTests/FallbackWeatherServiceTests -quiet
```
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Aether/Services/FallbackWeatherService.swift \
        Tests/AetherTests/FallbackWeatherServiceTests.swift
git commit -m "feat(weather): FallbackWeatherService — cascade primaire→fallback"
```

---

### Task 3: `WeatherKitWeatherService` + condition mapping (TDD on the pure part)

The WeatherKit fetch itself needs the entitlement + network and is verified manually. The `WeatherCondition` → `WeatherSnapshot.Condition` mapping is pure and test-driven.

**Files:**
- Test: `Tests/AetherTests/WeatherKitMappingTests.swift`
- Create: `Aether/Services/WeatherKitWeatherService.swift`

- [ ] **Step 1: Write the failing mapping test**

Create `Tests/AetherTests/WeatherKitMappingTests.swift`:

```swift
import Testing
import WeatherKit
@testable import Aether

/// Mapping pur condition WeatherKit → condition Domain. Hors ligne : on
/// construit des valeurs d'enum, sans requête ni entitlement.
struct WeatherKitMappingTests {
    @Test("Les conditions WeatherKit principales mappent vers le Domain")
    func mapsRepresentativeConditions() {
        #expect(WeatherSnapshot.Condition(weatherKit: .clear) == .clear)
        #expect(WeatherSnapshot.Condition(weatherKit: .partlyCloudy) == .partlyCloudy)
        #expect(WeatherSnapshot.Condition(weatherKit: .cloudy) == .cloudy)
        #expect(WeatherSnapshot.Condition(weatherKit: .foggy) == .fog)
        #expect(WeatherSnapshot.Condition(weatherKit: .rain) == .rain)
        #expect(WeatherSnapshot.Condition(weatherKit: .snow) == .snow)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodegen generate && xcodebuild test -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AetherTests/WeatherKitMappingTests -quiet
```
Expected: compile failure — no `init(weatherKit:)` on `WeatherSnapshot.Condition`.

- [ ] **Step 3: Implement the service + mapping**

Create `Aether/Services/WeatherKitWeatherService.swift`:

```swift
import Foundation
import CoreLocation
import WeatherKit

/// Source météo primaire via WeatherKit (entitlement `com.apple.developer.weatherkit`
/// requis). Toute erreur ou absence de donnée pour la date → `throw`, pour que
/// `FallbackWeatherService` bascule sur Open-Meteo. `WeatherKit.WeatherService`
/// est qualifié pour éviter la collision avec notre protocole `WeatherService`.
struct WeatherKitWeatherService: WeatherService {
    enum ServiceError: Error { case noDataForDate }

    func report(at coordinate: GeoCoordinate, date: Date) async throws -> WeatherReport {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let service = WeatherKit.WeatherService.shared

        // Fenêtre d'une heure autour de l'instant demandé.
        let hourStart = Calendar(identifier: .gregorian).date(
            bySetting: .minute, value: 0, of: date) ?? date
        let forecast = try await service.weather(
            for: location,
            including: .hourly(startDate: hourStart, endDate: hourStart.addingTimeInterval(3600)))

        guard let hour = forecast.first else {
            throw ServiceError.noDataForDate
        }

        let snapshot = WeatherSnapshot(
            condition: WeatherSnapshot.Condition(weatherKit: hour.condition),
            cloudCover: hour.cloudCover,
            humidity: hour.humidity,
            windSpeed: hour.wind.speed.converted(to: .metersPerSecond).value,
            temperature: hour.temperature.converted(to: .celsius).value)

        let attribution = try await Self.attribution()
        return WeatherReport(snapshot: snapshot, attribution: attribution)
    }

    private static func attribution() async throws -> WeatherAttribution {
        let credit = try await WeatherKit.WeatherService.shared.attribution
        return WeatherAttribution(
            serviceName: "\u{f8ff} Weather",   //  Weather
            legalURL: credit.legalPageURL,
            logoLightURL: credit.combinedMarkLightURL,
            logoDarkURL: credit.combinedMarkDarkURL)
    }
}

extension WeatherSnapshot.Condition {
    /// Mappe une `WeatherKit.WeatherCondition` vers le Domain. Les cas non
    /// énumérés retombent sur `.cloudy` (couverture moyenne plausible).
    init(weatherKit condition: WeatherCondition) {
        switch condition {
        case .clear, .mostlyClear, .hot:
            self = .clear
        case .partlyCloudy:
            self = .partlyCloudy
        case .cloudy, .mostlyCloudy:
            self = .cloudy
        case .foggy, .haze, .smoky:
            self = .fog
        case .drizzle, .rain, .heavyRain, .thunderstorms, .sleet, .hail:
            self = .rain
        case .snow, .heavySnow, .flurries, .blizzard:
            self = .snow
        default:
            self = .cloudy
        }
    }
}
```

Note: if the compiler reports an unknown `WeatherCondition` case in the switch, remove that case label — the `default` already covers it. Do not add cases you cannot confirm compile.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AetherTests/WeatherKitMappingTests -quiet
```
Expected: 1 test passes. (Build also confirms the WeatherKit fetch compiles, even without the entitlement.)

- [ ] **Step 5: Commit**

```bash
git add Aether/Services/WeatherKitWeatherService.swift \
        Tests/AetherTests/WeatherKitMappingTests.swift
git commit -m "feat(weather): WeatherKitWeatherService + mapping condition→Domain"
```

---

### Task 4: Entitlement + project config

**Files:**
- Create: `Aether/Aether.entitlements`
- Modify: `project.yml` (Aether target `settings.base`)

- [ ] **Step 1: Create the entitlements file**

Create `Aether/Aether.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.weatherkit</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 2: Reference it in `project.yml`**

In the `Aether` target's `settings.base` block (after `PRODUCT_NAME: Aether`), add:

```yaml
        CODE_SIGN_ENTITLEMENTS: Aether/Aether.entitlements
```

- [ ] **Step 3: Regenerate and build**

Run:
```bash
xcodegen generate && xcodebuild build -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```
Expected: BUILD SUCCEEDED. (Automatic signing picks up the entitlement; the live WeatherKit call only works once the App ID has the WeatherKit service enabled in the Apple Developer portal — see Task 6 docs.)

- [ ] **Step 4: Commit**

```bash
git add Aether/Aether.entitlements project.yml
git commit -m "build(weather): entitlement WeatherKit sur la cible Aether"
```

---

### Task 5: Wire the composite + attribution UI in `CanvasView`

**Files:**
- Modify: `Aether/Features/Canvas/CanvasView.swift`
- Modify: `Aether/Resources/Aether.xcstrings`

- [ ] **Step 1: Add the localized accessibility label**

In `Aether/Resources/Aether.xcstrings`, inside the `"strings"` object, add a new entry (after `"app.tagline"`'s closing `},`):

```json
    "attribution.weather" : {
      "comment" : "Libellé d'accessibilité du lien d'attribution de la source météo.",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Weather source"
          }
        },
        "fr" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Source météo"
          }
        }
      }
    },
```

- [ ] **Step 2: Swap the service and store attribution**

In `CanvasView.swift`, change line 18:

```swift
    private let weather = OpenMeteoWeatherService()
```

to:

```swift
    private let weather = FallbackWeatherService(
        services: [WeatherKitWeatherService(), OpenMeteoWeatherService()])
```

After the `cloudParameters` state (line 21), add:

```swift
    /// Attribution de la source météo réellement utilisée (nil avant résolution).
    @State private var attribution: WeatherAttribution?
```

Update `loadWeather()` (lines 52-60) to store the attribution:

```swift
    private func loadWeather() async {
        do {
            let report = try await weather.report(
                at: Self.defaultScene.coordinate, date: Self.defaultScene.date)
            cloudParameters = CloudParameters(weather: report.snapshot)
            attribution = report.attribution
        } catch {
            cloudParameters = .neutral
            attribution = nil
        }
    }
```

- [ ] **Step 3: Add the attribution overlay**

In `body`, add an overlay on the `ZStack` (after the `.gesture(...)`/`clearButton` block, before the closing `}` of the `ZStack` — i.e. attach `.overlay` to the `ZStack`). Replace the `ZStack { ... }` closing with the overlay attached:

```swift
            }
            .overlay(alignment: .bottomTrailing) {
                if let attribution {
                    weatherAttribution(attribution)
                        .padding(.trailing, 16)
                        .padding(.bottom, 40)
                }
            }
```

Then add this helper inside `CanvasView` (e.g. after `clearButton`):

```swift
    /// Lien d'attribution minimal, registre sobre. Affiche le logo de la source
    /// si fourni (WeatherKit), sinon son nom (Open-Meteo). Exigence légale Apple
    /// pour les données WeatherKit ; crédit CC-BY pour Open-Meteo.
    @ViewBuilder
    private func weatherAttribution(_ attribution: WeatherAttribution) -> some View {
        let content = Group {
            if let logoURL = attribution.logoDarkURL ?? attribution.logoLightURL {
                AsyncImage(url: logoURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Text(attribution.serviceName)
                }
                .frame(height: 12)
            } else {
                Text(attribution.serviceName)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)

        if let url = attribution.legalURL {
            Link(destination: url) { content }
                .accessibilityLabel(Text("attribution.weather", tableName: "Aether"))
        } else {
            content
        }
    }
```

- [ ] **Step 4: Regenerate, build and test**

Run:
```bash
xcodegen generate && xcodebuild test -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```
Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Aether/Features/Canvas/CanvasView.swift Aether/Resources/Aether.xcstrings
git commit -m "feat(weather): WeatherKit primaire + attribution dans le canvas"
```

---

### Task 6: Documentation + manual verification

**Files:**
- Modify: `CLAUDE.md` ("Reste à faire" → "État d'avancement")

- [ ] **Step 1: Update `CLAUDE.md`**

In the "Reste à faire" list, remove the line:

```markdown
- **WeatherKit** comme source primaire (entitlement requis) derrière `WeatherService`.
```

Add a new subsection after "Galerie + import photo — **terminé**" (registre sobre, French):

```markdown
## WeatherKit source primaire — **terminé**

- `WeatherService` renvoie un `WeatherReport` (snapshot + `WeatherAttribution`).
- `WeatherKitWeatherService` (Services) : source primaire via WeatherKit
  (entitlement `com.apple.developer.weatherkit`) ; toute erreur ou date hors
  fenêtre → `throw`.
- `FallbackWeatherService` : cascade `[WeatherKit, Open-Meteo]`, premier succès,
  log des bascules.
- `CanvasView` affiche l'attribution de la source réellement utilisée (logo
  WeatherKit + lien légal, ou crédit Open-Meteo).
- **Prérequis portail** : l'App ID `io.github.glandais.aether` doit avoir le
  service **WeatherKit** activé dans Apple Developer (propagation ~30 min).
  Avant cela, l'appel live échoue → fallback Open-Meteo silencieux.
- Tests : `FallbackWeatherServiceTests` (cascade), `WeatherKitMappingTests`
  (condition → Domain). L'appel WeatherKit live est vérifié manuellement.
```

- [ ] **Step 2: Commit the docs**

```bash
git add CLAUDE.md
git commit -m "docs: WeatherKit source primaire terminé"
```

- [ ] **Step 3: Manual verification on simulator**

Run the app:
```bash
xcodebuild build -scheme Aether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```
Then launch on the booted `iPhone 17 Pro` simulator (or via Xcode) and confirm:
- App launches to the canvas with the default Paris scene.
- A small attribution link appears at the bottom-trailing corner.
- With WeatherKit entitlement active: it shows the Apple Weather logo. Without portal activation: it falls back and shows "Open-Meteo".
- Painting a stroke still produces a cloud initialized from the weather.

Note any deviation. If WeatherKit returns data, the attribution logo confirms the primary path; if it shows Open-Meteo, the fallback path is confirmed working.

---

## Self-Review

- **Spec coverage:** Domain types (Task 1) ✓; protocol change (Task 1) ✓; `WeatherKitWeatherService` + mapping (Task 3) ✓; `FallbackWeatherService` (Task 2) ✓; CanvasView wiring + attribution UI (Task 5) ✓; entitlement/project.yml (Task 4) ✓; tests (Tasks 2,3) ✓; docs (Task 6) ✓; out-of-range→fallback handled by throw + composite (Tasks 2,3) ✓.
- **Type consistency:** `WeatherReport{snapshot,attribution}`, `WeatherAttribution{serviceName,legalURL,logoLightURL,logoDarkURL}`, protocol method `report(at:date:)`, `WeatherSnapshot.Condition(weatherKit:)` — used identically across tasks.
- **Placeholders:** none — every code/JSON/XML block is complete.
