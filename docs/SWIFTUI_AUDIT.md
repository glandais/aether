# SwiftUI Audit — Aether

> Code review of the SwiftUI layer against Apple's SwiftUI specialist guidance
> (view structure, data flow, ForEach identity, modifiers, soft-deprecated APIs,
> localization). Findings ordered by ROI: performance and correctness first.
>
> **Date:** 2026-07-11 · **Scope:** all 9 SwiftUI files (`App/`, `Features/`,
> `Rendering/MetalView.swift`) plus `CanvasModel`, Renderer entry points, and
> the services they touch.
>
> **Statut :** tous les findings (P1–P6, C1–C3, S1–S3) sont corrigés le
> 2026-07-11 — voir les commits `perf:`/`refactor:`/`fix:` correspondants sur
> `develop`. Le tableau ci-dessous est conservé comme trace de l'audit.

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
