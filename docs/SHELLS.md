# Multi-coquilles peintes — plan de travail

> **Statut : CONCEPTION VALIDÉE, non implémenté.** Relu contre la référence
> `realtime_clouds` (`Sky.metal`) et le `Cloud.metal` actuel ; les décisions de
> conception sont actées (§11). Les valeurs numériques (rayons, épaisseurs)
> restent *illustratives*, à caler par capture pendant l'implémentation.

## 1. Pourquoi

Le domaine de nuage actuel (`CloudCube`) confine la densité à des **AABB finis**
ancrés sur la direction de regard (atlas de slabs 3D, `intersectBox`, tri des
hits par pixel). Conséquences ressenties :

- La peinture est bornée : un cube fini, du vide entre/au-delà des cubes ; pas de
  ciel **continu** jusqu'à l'horizon.
- Le volume 3D peint n'apporte pas de vraie profondeur perçue — le « sculpté »
  ne convainc pas.
- Impossible d'éditer des **étages** distincts (cirrus haut, cumulus bas…).

Cible : reprendre le modèle **coquille sphérique** de la référence
`realtime_clouds` (raymarch HZD sur une couche enveloppant une « petite planète »)
et le rendre **éditable et multi-étages**.

## 2. Rappel de la référence (shell sphérique)

Voir `realtime_clouds/ios/RealtimeClouds/Shaders/Sky.metal`. Trois rayons :

```
g_radius     = 200000  // surface (rayon planète, volontairement petit)
sky_b_radius = 201000  // bas de la couche de nuages
sky_t_radius = 202300  // haut de la couche
```

- Caméra posée sur la surface : `camPos = (0, g_radius, 0)`.
- Nuages dans une **coquille de 1,3 km** enveloppant toute la planète.
- Par pixel, on marche entre l'entrée (`intersectSphere(..., sky_b_radius)`) et
  la sortie (`..., sky_t_radius`) de la coquille, **si le rayon monte**
  (`dir.y > 0`).
- **Où il y a du nuage** = échantillonnage d'une carte de couverture 2D en
  `p.xz` (position horizontale) : `weather.x` → couverture. Pas de domaine borné.
- `height_fraction = (length(p) - sky_b_radius) / (sky_t_radius - sky_b_radius)`
  → coordonnée verticale **dans** la coquille.
- `densityHeightGradient(height_fraction, cloudType)` → **profil vertical** du
  nuage (stratus aplati … cumulus haut). `cloudType` est figé à `0.5` dans le
  port.

Distinction à garder en tête :

- `height_fraction` = position verticale dans **une** coquille (≠ étage).
- `cloudType`/`densityHeightGradient` = **forme/genre** du nuage.
- `weather` (`p.xz`) = variation **horizontale** (← c'est là que branche la
  peinture).
- **Étages cirrus/bas** = **coquilles concentriques multiples** (le présent plan).

## 3. Renversement conceptuel

**1 calque éditable = 1 coquille concentrique.** La peinture devient une **carte
de couverture 2D directionnelle** (azimut × élévation), pas un volume 3D.

Insight clé : le long d'un rayon de vue, la direction est **constante**
(`p = œil + t·dir`). Donc :

- la couverture, indexée par la direction, se sample **une seule fois par pixel** ;
- peindre à l'écran mappe **1:1** sur la couverture (peindre où l'on regarde =
  poser de la couverture dans cette direction) ;
- le relief vient **gratuitement** de la géométrie de coquille
  (`height_fraction`) + du bruit 3D (échantillonné en `p`, qui varie le long du
  rayon).

On **abandonne** le volume 3D peint : le « sculpté » n'apportait pas de profondeur
réelle de toute façon.

| Aujourd'hui (cubes) | Multi-coquilles |
|---|---|
| `CloudCube` = AABB fini ancré au regard | `CloudLayer` = coquille infinie à une altitude |
| Densité peinte en **volume 3D** (atlas slabs 96×96×48) | Couverture peinte en **carte 2D** par direction |
| `intersectBox` + tri de 16 hits / pixel | `intersectSphere` ×N coquilles, **ordre fixe** |
| Profondeur = gaussienne factice le long du rayon | Profondeur = épaisseur de coquille + `height_fraction` + bruit |
| « Nouveau cube quand le regard change » | Calque actif sélectionné dans l'UI |

## 4. Modèle Domain

```swift
/// Genre de nuage : fixe l'étage (rayons de la coquille), le profil vertical
/// (`cloudType` pour `densityHeightGradient`) et le caractère du bruit. Source
/// unique des constantes par étage — l'analogue météo de `CloudParameters`.
enum CloudGenus: String, Codable, Sendable, CaseIterable {
    case cirrus       // haut, mince, fibreux
    case altocumulus  // moyen, floconneux
    case cumulus      // bas, épais, bourgeonnant

    var shell: ShellSpec {
        switch self {
        case .cirrus:      .init(inner: 207_000, outer: 207_600, cloudType: 0.05, noiseScale: 6.4e-4, drift: .init(0.030, 0.004))
        case .altocumulus: .init(inner: 204_000, outer: 205_000, cloudType: 0.45, noiseScale: 3.9e-4, drift: .init(0.016, 0.006))
        case .cumulus:     .init(inner: 201_000, outer: 203_000, cloudType: 0.85, noiseScale: 3.0e-4, drift: .init(0.010, 0.004))
        }
    }
}

/// Constantes d'une coquille, dérivées du genre. (Rayons illustratifs.)
struct ShellSpec: Sendable {
    var inner: Float; var outer: Float   // m au-dessus du centre planète
    var cloudType: Float                 // 0 stratus … 1 cumulus
    var noiseScale: Float                // m⁻¹, en coordonnées planète (cf. note)
    var drift: SIMD2<Float>
}
```

> **Attention aux unités de `noiseScale`** : le raymarch coquille opère en
> coordonnées planète (`p ≈ 2·10⁵ m`) ; la référence sample son bruit à
> `p * 0.0003` (`Sky.metal:548`). Le `kNoiseScale = 0.42` actuel d'Aether est
> calé sur les unités monde des cubes et **ne se transpose pas** — l'utiliser
> tel quel donnerait de l'aliasing pur. Ordre de grandeur correct : ~3·10⁻⁴,
> modulé par genre (valeurs ci-dessus = ratios du brouillon ramenés à cette
> échelle, à caler par capture).

```swift
/// Une coquille éditable = un calque. Concentrique aux autres ; porte ses traits
/// (carte de couverture par direction) et ses paramètres météo. Remplace
/// `CloudCube` : plus d'`anchorForward`, l'étage vient du `genus`.
struct CloudLayer: Equatable, Sendable, Codable {
    var genus: CloudGenus
    var strokes: [BrushStroke]      // inchangé : points écran + pose au dépôt
    var coverageBias: Float = 0     // ex-CloudParameters.coverageBias, par calque
    var opacity: Float = 1          // ex-densityScale
    var isVisible: Bool = true      // toggle de calque (éditeur d'images)

    /// Un calque par étage + marge.
    static let maxCount = 4
}
```

- `BrushStroke` **inchangé** (`points` écran [0,1]² + `StrokeCamera`). Seule la
  cible de cuisson change (carte 2D directionnelle au lieu du voxel 3D).
- `CanvasModel` : `cubes: [CloudCube]` → `layers: [CloudLayer]` + `activeGenus`.
  La logique « nouveau cube quand le regard change » disparaît ; tout trait va
  dans le **calque actif**. Undo/redo : instantané de `layers` (inchangé).
- `CloudParameters` (coverageBias/densityScale issus du `WeatherSnapshot`)
  alimente désormais des **valeurs par défaut par calque** — défaut retenu :
  mêmes valeurs pour tous les calques, ajustables par calque ensuite (cf. §12).

## 5. Peinture → couverture directionnelle

Carte de couverture d'un calque = **équirectangulaire hémisphère supérieur**
(azimut × élévation ∈ [0°, 90°]), une tranche d'un atlas 2D `texture2d_array`
**1024×512 × `maxCount`, format `R8Unorm`** — échantillonné en
`filter::linear`, donc ≤ 16 bits obligatoire (piège `R32Float` non filtrable
sur GPU iOS, cf. CLAUDE.md « Pièges connus »).

**Sous l'horizon : rien** (décision actée). Le domaine de la carte s'arrête à
l'élévation 0 ; les points de trait sous la ligne d'horizon ne déposent rien
(pas de clamp, pas de marge négative). Un dab à cheval sur l'horizon ne dépose
que sa partie ≥ 0° — débordement naturel du pinceau, acceptable.

Le kernel de stamp reste **texel-centrique** (comme `stamp_density_volume`
aujourd'hui), mais en **2D** et **sans** la gaussienne de profondeur :

```metal
float2 uv = (float2(gid.xy) + 0.5) / dims;          // [0,1]² équirect
float az = (uv.x - 0.5) * 2.0 * PI;                 // azimut
float el = uv.y * (PI * 0.5);                       // élévation (hémisphère sup.)
float3 dir = float3(sin(az)*cos(el), sin(el), -cos(az)*cos(el)); // -Z = Nord

float zc = dot(dir, U.camForward.xyz);
if (zc > 1e-4) {
    float2 canvas = projectToCanvas(dir, U);        // projection de BrushPaint, sans depthProfile
    coverage = max(coverage, testDabs(canvas, dabs, count)); // dabs/softness identiques
}
dst.write(max(existing, coverage), gid);            // pas de depthProfile
```

→ On **supprime** `depthProfile`, `boxCenter`, `depthSigma` et l'atlas 3D. La
projection écran→canvas (`xc/yc/zc`, NDC, UV) est reprise telle quelle de
`BrushPaint.metal`.

## 6. Rendering — raymarch concentrique

Dans `Cloud.metal`, le bloc « gather + tri des cubes » disparaît. Les coquilles
sont **nichées** : un rayon montant traverse d'abord la plus basse → front-to-back
= altitude croissante, **aucun tri**.

```metal
float3 camPos = float3(0.0, g_radius, 0.0);
float3 rd = /* reconstruit depuis camRight/Up/Forward — inchangé */;
if (rd.y <= 0.0) return float4(0.0);                // sous l'horizon

float2 covUV = directionToEquirect(rd);             // couverture constante / rayon

float transmittance = 1.0;
float3 scattered = float3(0.0);

for (uint L = 0; L < u.layerCount; ++L) {           // ordre fixe = altitude croissante
    Shell sh = u.shells[L];
    float cov = coverageAtlas.sample(s, covUV, L).r + sh.coverageBias;
    if (cov <= 0.001) continue;                      // rien peint dans cette direction

    float3 start = camPos + rd * intersectSphere(camPos, rd, sh.inner);
    float3 end   = camPos + rd * intersectSphere(camPos, rd, sh.outer);
    int steps = int(mix(96.0, 54.0, rd.y));

    // Cap the step length near the horizon (reference `dmod`, Sky.metal:663-664).
    // At grazing angles the shell traversal reaches ~14x the shell thickness;
    // dividing it uniformly would give huge steps and banding right where the
    // gaze rests. The capped march covers only part of the traversal there --
    // acceptable, transmittance saturates first.
    float tdist = sh.outer - sh.inner;
    float dmod  = smoothstep(0.0, 1.0, (length(end - start) / tdist) / 14.0);
    float ss    = mix(tdist, tdist * 4.0, dmod) / float(steps);
    float3 p = start, step = rd * ss;

    for (int i = 0; i < steps; ++i, p += step) {
        float hf = (length(p) - sh.inner) / (sh.outer - sh.inner);  // height_fraction DU calque
        float g  = densityHeightGradient(hf, sh.cloudType);         // profil = genre
        float n  = noise.sample(noiseSampler, p * sh.noiseScale + drift(sh, u.time));
        float density = shapeFrom(cov, g, n);        // cf. note « shapeFrom » ci-dessous
        if (density > 0.001) {
            // … éclairage actuel conservé : octaves de multiple-scattering,
            //   dualPhase(HG), powder, sunColor/skyAmbient injectés du CPU.
            //   Marche de lumière BORNÉE à la coquille courante (auto-ombrage
            //   seul, décision §11) ; elle réutilise `cov` (constant par pixel).
            // accumulation transmittance/scattered PARTAGÉE entre calques :
            // un cirrus translucide laisse voir le cumulus dessous.
        }
    }
    if (transmittance < 0.01) break;                 // opaque : étages plus hauts masqués
}

float alpha = 1.0 - transmittance;
return float4(scattered, alpha);
```

`height_fraction` et `cloudType` retrouvent leur vraie place : chacun opère dans
**sa** coquille ; c'est l'**empilement** de coquilles qui crée les étages, pas
`height_fraction` seul.

**Note `shapeFrom` — ne pas importer la fenêtre de couverture de la
référence.** `density()` de référence fait
`cloud_coverage = smoothstep(0.6, 1.3, weather.x)` (`Sky.metal:552`) : pensée
pour une texture météo procédurale, cette fenêtre annulerait toute couverture
peinte < 0.6 — la moitié basse des traits disparaîtrait. Garder la chaîne de
remap actuelle de `cloudDensity` (`Cloud.metal:127-130`, calée sur la
peinture : `base = remap(n.r, 1-painted, …)` puis érosion par le détail) et y
**multiplier** le gradient de hauteur `g`. Le `densityHeightGradient` /
`mixGradients` de la référence (`Sky.metal:511-525`) se porte tel quel —
Aether n'a aujourd'hui ni gradient de hauteur ni `height_fraction` (la forme
venait du volume peint).

## 7. Ce qui est supprimé / simplifié

| Supprimé | Remplacé par |
|---|---|
| Atlas densité 3D (`densityVolumes` 96×96×48 × maxCount, ping-pong) | Atlas couverture 2D array (≈1024×512 × maxCount) — bien plus léger |
| `intersectBox` + gather 16 hits + tri / pixel | `intersectSphere` × maxCount (≤4), ordre fixe |
| `CloudCubeGPU` + `anchorForward` + `cubeCenter()` | `Shell` (inner/outer/cloudType/noiseScale/drift) par genre |
| `depthProfile`/gaussienne dans `stamp` | rien (stamp 2D) |
| Logique « nouveau cube quand le regard change » | `activeGenus` sélectionné dans l'UI |

## 8. Compromis connus (assumés)

- **Parallaxe horizontale** : la référence sample en `p.xz` (varie le long du
  rayon → étirement vers l'horizon). En directionnel-constant on le perd ; la
  convergence à l'horizon reste assurée par la géométrie de coquille + le bruit
  3D (qui varie en `p`). Récupérable en samplant la couverture à la direction de
  `p` plutôt que `rd`, au coût d'un sample/pas. **Défaut : `rd` (constant), à
  comparer par capture à l'étape 3.**
- **Couverture constante dans la marche de lumière** : la référence sample
  `weather` à chaque pas de lumière (`Sky.metal:601`) ; en directionnel-constant
  le rayon de lumière « ne voit pas » qu'il sort du nuage peint — auto-ombrage
  légèrement faux en bord de trait. Même arbitrage que la parallaxe (sampler la
  couverture à `normalize(q)` par pas de lumière si la capture l'exige).
- **Pas d'ombrage croisé entre coquilles** (décision §11) : un cirrus dense
  n'assombrit pas le cumulus dessous ; chaque coquille ne s'ombre qu'elle-même.
- **Stamp purement additif** (`max`), pas de gomme en v2 : seul l'undo retire de
  la matière (décision §11).
- **Distorsion aux pôles** de l'équirect : faible (on ne peint que l'hémisphère
  sup.) ; le stamp texel-centrique évite la déformation des disques.
- **Perf** : `layerCount × steps` (≈ 4 × 70) vs aujourd'hui (12 cubes × 64) — même
  ordre de grandeur. `continue` sur couverture nulle + break sur opacité tiennent
  le budget. Passe temporelle 2×2 conservée. **À profiler sur device.**

## 9. Plan d'implémentation séquencé

Chaque étape se vérifie par **capture sur simulateur** (cf. CLAUDE.md). Préférence
proposée : valider d'abord **une seule coquille peinte** à fonctionnalité égale
avant d'ajouter les étages.

1. **Domain** : `CloudGenus` + `ShellSpec` + `CloudLayer`. Tests purs (rayons
   cohérents, `density` shape mapping si extrait en util testable).
2. **Stamp 2D** : `stamp_coverage_map` (kernel 2D), atlas `texture2d_array`
   1024×512 `R8Unorm`, domaine hémisphère sup. (pas de dépôt sous l'horizon).
   Retirer `depthProfile`. Capture : un trait → tache de couverture correcte.
3. **Raymarch une coquille** : remplacer cubes/atlas par **une** coquille
   `cumulus` lisant la couverture peinte — avec le pas borné `dmod` (§6) et la
   chaîne de remap actuelle × gradient de hauteur. Parité visuelle vs cubes ;
   capture dédiée à l'horizon (banding) et au bord de trait (auto-ombrage).
4. **Multi-coquilles** : boucle concentrique, `layerCount` calques, accumulation
   partagée. Capture cirrus + cumulus simultanés. Si le cirrus manque de
   fibreux : porter l'érosion « hq » de la référence (Worley haute fréquence +
   distorsion curl, `Sky.metal:556-562`) — raffinement optionnel, Aether n'a
   aujourd'hui qu'une seule RGBA Perlin-Worley.
5. **UI calques** (`Features/Canvas`) : sélecteur de calque actif (genre),
   visibilité, opacité. Registre sobre/atmosphérique.
6. **Météo → défauts par calque** : brancher `CloudParameters`/`WeatherSnapshot`.
7. **Persistance `.aether`** : bump de schéma `version: 2`, refus propre des
   fichiers v1 (cf. §10).
8. **Nettoyage** : retirer `CloudCube`, `CloudCubeGPU`, atlas 3D, `cubeCenter`,
   logique multi-cubes du `CanvasModel`. `scripts/verify.sh` vert.

## 10. Persistance `.aether`

**Décision actée : pas de rétrocompatibilité** (l'app n'est pas publiée). Le
schéma passe de `[CloudCube]` à `[CloudLayer]` avec bump franc de
`AetherDocument.version` (1 → 2) ; les fichiers v1 sont refusés avec un message
propre. Le champ `version` existant (`AetherDocument.swift`) laisse la porte
ouverte à de vraies migrations futures. Voir `docs/PERSISTENCE.md`.

## 11. Décisions actées (2026-06)

- **Migration `.aether`** : bump franc `version: 2`, pas de rétrocompat (§10).
- **Sous l'horizon** : les points de trait sous l'élévation 0 ne déposent rien ;
  pas de clamp, pas de marge négative dans la carte (§5).
- **Ombrage croisé** : auto-ombrage seul — la marche de lumière est bornée à la
  coquille courante, comme le light march actuel borné au cube. À réévaluer par
  capture à l'étape 4 si l'empilement paraît faux.
- **Effacement** : rien en v2 — pas de gomme, pas de « vider le calque » ;
  undo/redo (instantané de `layers`) suffit. À revoir à l'usage.
- **Paramétrisation de la carte** : équirect hémisphère sup. uniquement,
  1024×512, `R8Unorm` (§5).
- **Drift** : le bruit dérive, la couverture peinte reste fixe dans sa direction
  (comportement de la référence, `p.x += time` dans `density()` seulement) — le
  nuage bouillonne sur place, il ne s'enfuit pas.

## 12. Restent à caler par capture

- **Rayons/épaisseurs par genre** : valeurs §4 illustratives (séparation visible
  des étages, convergence à l'horizon).
- **`noiseScale` par genre** : ordre de grandeur fixé (~3·10⁻⁴, §4), ratios à
  affiner.
- **Parallaxe** : couverture en `rd` (défaut) vs en `p` (1 sample/pas) — même
  arbitrage pour la marche de lumière (§8). Capture comparative à l'étape 3.
- **Météo multi-calques** (étape 6) : défaut proposé — `WeatherSnapshot` fournit
  les mêmes `coverageBias`/`opacity` par défaut à tous les calques, ajustables
  ensuite par calque ; affiner si un modulage par genre s'avère nécessaire.
- **Regard libre** : on garde yaw/pitch ; le regard ne crée plus de domaine — la
  cohérence peinture/rendu repose sur le mapping directionnel partagé entre
  `stamp` et raymarch ; à vérifier en peignant puis tournant le regard.
- **Bruit cirrus** : la RGBA Perlin-Worley seule suffira-t-elle ? Sinon, érosion
  Worley HF + curl de la référence (étape 4, raffinement optionnel).
- **Nombre de calques** : `maxCount = 4` suffisant ? (cirrus / alto / cumulus +1.)

## 13. Références

- `realtime_clouds/ios/RealtimeClouds/Shaders/Sky.metal` — shell HZD de
  référence (dépôt local : `~/code/other/realtime_clouds`). Repères :
  gradients de hauteur `:511-525`, fenêtre de couverture `:552`, érosion
  curl/Worley HF `:556-562`, light march cône `:599-610`, pas borné `dmod`
  `:663-664`.
- `docs/PIPELINE.md` — pipeline de rendu actuel (cubes).
- `BIBLIO.md` — papers (Schneider/Nubis, HZD, scattering).
- Code remplacé : `Aether/Domain/CloudCube.swift`,
  `Aether/Rendering/Shaders/BrushPaint.metal`, `…/Cloud.metal`,
  `Aether/Features/Canvas/CanvasModel.swift`, parties cubes/atlas de
  `Aether/Rendering/Renderer.swift`.
</content>
</invoke>
