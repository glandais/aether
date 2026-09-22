# SwiftUI Audit — Aether

> Code review of the SwiftUI layer against Apple's SwiftUI specialist guidance
> (view structure, data flow, ForEach identity, modifiers, soft-deprecated APIs,
> localization). Findings ordered by ROI: performance and correctness first.
>
> **Date:** 2026-07-11 · **Scope:** all 9 SwiftUI files (`App/`, `Features/`,
> `Rendering/MetalView.swift`) plus `CanvasModel`, Renderer entry points, and
> the services they touch.
>
> **Statut :** une première passe (2026-07-11, commits `394f04b`, `879a6e7`,
> `174083f`, `a550622`) traitait tous les findings (P1–P6, C1–C3, S1–S3). Une
> re-vérification du 2026-09-22 a montré que **P1, S2 et S3** n'étaient que
> partiellement corrigés, et que **P5, C1, C2 et C3** gardaient des points
> mineurs. Tous sont complétés par les correctifs du 2026-09-22 — voir les
> commits correspondants sur `develop`. Build, SwiftLint `--strict`, Periphery,
> `xcodebuild analyze` (0 avertissement) et tests (67, 0 échec) sont verts ;
> quelques points mineurs non bloquants restent ouverts, listés dans
> « Re-verification (2026-09-22) ». Les findings ci-dessous sont conservés tels
> quels comme trace de l'audit.

## Summary

The overall picture is healthy: `@Observable` (not `ObservableObject`) with
`@MainActor`, gestures correctly delegated to UIKit, star recomputation already
keyed out of `body` behind `.task(id:)`, and the Renderer doing its own change
detection. The two highest-ROI items are **P1** (single giant invalidation
boundary in `CanvasView` with expensive astro/scattering work recomputed per
body pass) and **P2** (the DEBUG FPS badge invalidating the whole canvas and
skewing its own measurement).

| ID | Priority | Type | Finding |
|----|----------|------|---------|
| P1 | High | Perf | `CanvasView` is one invalidation boundary; `resolvedLight` recomputed every body pass |
| P2 | High | Perf (DEBUG) | FPS badge read invalidates the whole canvas every second |
| P3 | Medium | Perf | `DateFormatter` allocated per body evaluation |
| P4 | Medium | Perf | `CanvasModel.strokes` allocates a flattened array per read |
| P5 | Medium | Perf | Star recompute + GPU buffer rebuild every frame during autoplay |
| P6 | Medium | Perf | Ephemeris recomputed per tick while sheet is open |
| C1 | Medium | Correctness | Soft-deprecated `Alert` API in `GalleryView` |
| C2 | Medium | Correctness | Synchronous file read on the main thread |
| C3 | Low | Correctness | Time-zone resolution can race the coordinate |
| S1–S3 | Low | Style | Closure bindings · services recreated per init · localization details |

---

## High priority — performance

### P1. `CanvasView` is one giant invalidation boundary; `resolvedLight` recomputed inside it on every body pass

`CanvasView.swift:179` — the entire canvas (Metal view, time bar, tool
palette, panels) lives in a single view's body, built from computed properties
and `@ViewBuilder` funcs. Per Apple's guidance, those do **not** create
invalidation boundaries — any state change re-runs everything. The first line
of `body` is `let light = resolvedLight` (`CanvasView.swift:449`), which does
real CPU work: two SwiftAA planetary positions, moon illumination, two 16-step
atmospheric scattering integrals (`Atmosphere.swift:75`, each step calling
`opticalDepthToSpace`), and two sun transmittances.

That full recompute currently runs on body evaluations that cannot change the
light at all:

- every frame of a **brush-radius/softness or opacity slider drag** (the
  bindings write into `model`, which body reads),
- every **panel toggle / options fold animation**,
- every painted **stroke point** (`extendStroke` mutates `layers`, which body
  reads via `MetalView`),
- in DEBUG, every FPS update (see P2).

It also legitimately runs ~30×/s during autoplay and on every rotation frame —
but there, only the cheap gaze-mixing part actually depends on the gesture;
the astro positions and scattering integrals depend solely on
`(effectiveDate, effectiveCoordinate)`.

**Suggested fix, two independent halves:**

1. Split `ResolvedLight` into a cached, date/place-keyed part (astro
   positions, sun transmittance, zenith/horizon radiance, moon lighting) —
   recomputed via `.task(id:)` / `.onChange` keyed on
   `(effectiveDate, coordinate)`, exactly like the existing `starKey` pattern —
   and a per-body gaze part (camera-space direction mixing), a handful of SIMD
   ops that are fine inline.
2. Factor the chrome into separate `View` structs with narrow inputs
   (`TimeBar`, `ToolPalette`, `PaintPanel`, `PositionPanel`…) instead of
   computed properties. A brush-slider drag then invalidates only
   `PaintPanel`, not the world.

### P2. DEBUG FPS badge invalidates the whole canvas — and skews the measurement it displays

`CanvasView.swift:546` — `debugFPSBadge` reads `DebugHUD.shared.fps` inside
`CanvasView`'s body (via the overlay closure), so every 1 Hz FPS write re-runs
the **entire** `CanvasView` body, including `resolvedLight` and the full
`MetalView` diff/update. The profiling tool perturbs the profile.

**Fix:** extract a standalone `struct DebugFPSBadge: View` that reads
`DebugHUD.shared` in its own body — the 1 Hz tick then invalidates only that
tiny view. Five-minute fix with direct payoff for the on-device perf-profiling
roadmap item.

---

## Medium priority — performance

### P3. `DateFormatter` allocated on every body evaluation

`CanvasView.swift:779` (`timeLabel`) creates and configures a new
`DateFormatter` per call — per body pass, i.e. ~30×/s during autoplay and on
every rotation/paint frame. `DateFormatter` init is one of the classically
expensive Foundation allocations.

**Fix:** cache one `static` formatter and set `timeZone` per call, or use
`Date.FormatStyle` (`.hour(.twoDigits(amPM: .omitted)).minute()` with an
explicit time zone) via `Text(date, format:)`. Same pattern in
`EphemerisView.swift:74` (colder path — a formatter per row per sheet render —
same one-line fix).

### P4. `CanvasModel.strokes` allocates a flattened array per read

`CanvasModel.swift:67` — `layers.flatMap(\.strokes)` builds a fresh array on
every access, and body reads it twice per pass (`hasEdits`, the clear bubble's
`enabled:`). Only emptiness is ever consulted.

**Fix:** replace with a non-allocating
`var hasStrokes: Bool { layers.contains { !$0.strokes.isEmpty } }`.

### P5. Star recomputation runs every frame during autoplay

`starKey`'s 60 s bucket (`CanvasView.swift:268`) is 60 s of *simulated* time.
At 1× autoplay (0.25 h/s) the bucket flips ~15×/s; at 16×, on every tick. Each
flip cancels/restarts the `.task`, runs the 9 000-star trig loop on the main
actor, and bumps `starRevision`, forcing a GPU star-buffer rebuild in the
Renderer.

Stars moving during a timelapse is presumably intended, but consider
throttling to real display time (e.g. also bucket by wall clock) or coarsening
the bucket while autoplay is active — and the loop could run off the main
actor.

### P6. Ephemeris recomputed per tick while the sheet is open

`CanvasView.swift:238` — `astro.ephemeris(...)` is evaluated in the sheet's
content closure, which re-evaluates with the parent body. With autoplay
running behind the `.medium` sheet, the iterative rise/set search runs
~30×/s.

**Fix:** compute once when presenting (store in `@State`, like `saveDocument`)
— or accept it if live-updating ephemeris during timelapse is a feature.

---

## Correctness

### C1. Soft-deprecated `Alert` API in `GalleryView`

`GalleryView.swift:71` uses `.alert(item:content:)` with the `Alert` struct —
both are on Apple's soft-deprecated list. Modern replacement:

```swift
.alert(
    Text(String(localized: openError?.messageKey ?? "gallery.openError", table: "Aether")),
    isPresented: .init(get: { openError != nil }, set: { if !$0 { openError = nil } })
) { Button(String(localized: "action.confirm", table: "Aether")) {} }
```

(or the `presenting:` overload to keep the enum). Informational, not urgent —
it still compiles and works.

### C2. Synchronous file read on the main thread

`GalleryView.swift:83` — `Data(contentsOf:)` runs on the main actor with a URL
from `fileImporter`. A `.aether` file in iCloud Drive that isn't downloaded
locally will block the UI (or fail) for the duration of the fetch.

**Fix:** wrap read + decode in a `Task` off the main actor and hop back to
call `onSelect` / set `openError`.

### C3. Time-zone resolution can race the coordinate

`CanvasView.swift:235` — picking a location applies `coordinateOverride`
immediately and resolves the zone in a fire-and-forget `Task`;
`resetToHereAndNow` does the same. Two quick successive picks (or a pick
racing "here & now") can land writes out of order, leaving a
`timeZoneOverride` that doesn't match `coordinateOverride` — which shifts
`effectiveDate` and thus the whole sky, not just the label.

**Fix (cheap):** capture the coordinate and only assign if it still matches,
or keep a single cancellable resolution task.

---

## Lower priority / style

### S1. Closure bindings

`binding(_:)` (`CanvasView.swift:1048`), `opacityBinding`, and the local
`hour`/`day` bindings are get/set closures, which the data-flow guidance flags
(heap allocation per body pass, defeats binding comparison). For `CanvasModel`
properties the idiomatic form is `@Bindable var model = model` then
`$model.brushRadius`. The `hourOverride ?? default` bindings genuinely need
logic, so a labeled subscript on the view/model would be the pattern to go all
the way; otherwise fine to leave.

### S2. Services recreated per `CanvasView.init`

`astro`, `timeZoneService`, `locationService` are stored `let`s initialized in
the struct, so every re-init makes fresh instances (`CLLocationManager`
allocation; the tzf actor drops its lazily-loaded polygon cache between
scenes). `RootView` re-evaluates rarely so impact is low, but holding them in
`@State` (or injecting from `RootView`) matches the "keep init cheap" rule.
Same for the throwaway `CanvasModel()` built on every init before
`State(initialValue:)` discards it.

### S3. Localization details

- `locationLabel` (`CanvasView.swift:693`) and `LocationPickerView.format`
  hardcode `N/S/E/W` (fr would want `O` for ouest) and duplicate each other.
- `EphemerisView.illumination` hardcodes `%` instead of `.percent` formatting.
- `timeLabel` forces `en_US_POSIX HH:mm` (deliberate 24 h style, presumably —
  if so, `Date.FormatStyle` can express that intent locale-safely).

---

## Checked and found healthy

- `@Observable` + `@MainActor` on `CanvasModel` and `DebugHUD`; `CloudLayer`
  is `Equatable`, so the observation setter can short-circuit.
- `ForEach` identities all stable (enum cases, `Identifiable` catalog); no
  index-based or per-body-generated ids.
- No conditional-`.if` modifiers; no `AnyView` rows.
- `MetalView`'s `contentID` / `starRevision` change-detection pattern is
  exactly right; the `MTKView` pause-on-background lifecycle handling is a
  nice touch.
- `.task(id:)` usage for autoplay and stars is idiomatic (structured
  cancellation, no timers).

## Suggested order of attack

**P2** (trivial, unblocks honest profiling) → **P1** (the structural win) →
**P3/P4** (small, ride along with P1's refactor) → **C1/C2** → the rest as
opportunity allows.

---

## Re-verification (2026-09-22)

A second look at the first-pass fixes found gaps. The findings above are left
unchanged; this table records what the first pass left and what was completed.
P2, P3, P4, P6 and S1 were confirmed fixed by the first pass (S1's remaining
closure bindings were removed as part of P1).

| ID | After the first pass | Completed on 2026-09-22 |
|----|----------------------|-------------------------|
| P1 | Light cached by date/place, but chrome still built from computed properties inside `CanvasView` (904 lines); `PaintPanel` read `model.layers`, so every stroke point re-ran it | Chrome split into `ToolPalette`, `MorePanel`, `PositionPanel` (new files); `PaintPanel` takes an `Equatable` `LayerSummary` per genus and is skipped on stroke points; `body` resolves default hour/day and instant once; `TimeBar`/`PositionPanel` use an `Optional[orDefault:]` subscript instead of closure bindings. `CanvasView` is now ~640 lines |
| S2 | `CanvasView.init` still built a `CLLocationManager` (via the location service) and a throwaway `CanvasModel()` | `CLLocationManager` is a `lazy var` in `CoreLocationService`; `CanvasModel(context:restored:)` is built once per scene in `RootView.open(_:restored:)` (gallery, `.aether` reopen and `ScreenshotHarness`) and passed in |
| S3 | Compass points and `%` localized, but the clock still used an `en_US_POSIX` `DateFormatter` and coordinates used `String(format: "%.1f")` | Shared `ClockTime.format(_:timeZone:)` (24 h `Date.VerbatimFormatStyle`, explicit time zone) used by `CanvasView` and `EphemerisView`, covered by `ClockTimeTests`; `CoordinateLabel` formats degrees with the locale's decimal separator and picks the pair separator from it (" ; " when the decimal is a comma, e.g. "48,9°N ; 2,4°E", otherwise ", ") |
| P5 | Star recompute moved off the main actor, but a late result for an old key could overwrite a newer one | `guard !Task.isCancelled` before assigning `starField` / bumping `starRevision` |
| C1 | Modern `.alert`, but the title was derived from an optional cleared on dismiss (empty-title flash) | `openError` keeps the last error; a separate `showOpenError` Bool drives the alert |
| C2 | Read moved into a `Task`, but `load(_:)` could still run on the main actor | `load(_:)` marked `@concurrent` |
| C3 | Stale comment; pick applied the coordinate before the zone; concurrent lookups could overwrite each other | Coordinate and zone written together after the tzf lookup; a single `locationTask` (`replaceLocationTask`) cancels the previous lookup; both paths check `Task.isCancelled` before writing |

**Verification:** build OK; SwiftLint `--strict` and Periphery clean;
`xcodebuild analyze` succeeded with 0 warnings; 67 Swift Testing tests in 15
suites passed; simulator screenshots (en and fr, `noon:13:shown:cumulus`,
`dusk:18.5:shown:perf`, "More" and position panels) render correctly at 60 fps.

**Still open (minor, not blocking):**

- "Here & now": `isResolvingHereNow = true` is now set inside the task, so for
  one frame after the tap the button is not disabled and no spinner shows. A
  second tap restarts the lookup, so the result is still correct. Fix: set it
  right after `replaceLocationTask` returns.
- `CoreLocationService`: a late `didUpdateLocations` from a cancelled request
  can resume the next request's continuation. It returns a real, recent
  location, so there is no functional impact.
- `LocationPickerView` shares the location service: starting a GPS lookup there
  silently cancels a pending "here & now" (its spinner turns off correctly).
- `ToolPalette.body` (and `MorePanel` when open) still re-run on every stroke
  point because they take closures; accepted, as the costly `PaintPanel` is
  skipped.
- One local `Binding(get:set:)` remains for the opacity slider in `PaintPanel`.
- A running place lookup is not cancelled when the canvas disappears.
