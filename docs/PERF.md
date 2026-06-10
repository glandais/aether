# Performance — moteur de rendu Aether

Journal des optimisations du pipeline Metal et registre des pistes restantes.
Le pipeline lui-même est décrit dans [`PIPELINE.md`](PIPELINE.md) ; ce document
se concentre sur le **coût** et la **méthode de mesure**.

> **Device de référence : iPhone 13 Pro Max (A15).** Le simulateur n'est **pas**
> représentatif de la perf GPU (et MetalFX y est absent) — toute mesure perf se
> fait sur device réel. La cible est **60 ips** au repos (registre contemplatif :
> l'app est surtout regardée immobile).

## Résumé de l'état

Profilage et optimisation menés par mesure sur device (juin 2026). Scène de
référence : pire cas **3 étages** (cumulus + altocumulus + cirrus, couverture
large) + mer, midi — injectée par le harnais (`AETHER_SHOT=noon:13:…:perf`).

Trajet mesuré (repos / mouvement), chaque étape cumulative :

| Étape | Repos | Mouvement |
|---|---|---|
| Départ | 15 | 15 |
| Amortissement **nuage** réparé (compute compact) | 33 | 22 |
| Amortissement **ciel** (compute compact) | 39 | 25 |
| Réduction des pas **mer** + upscale **MetalFX** | *à re-mesurer* | *à re-mesurer* |

Les deux dernières optimisations (mer, MetalFX) ont été ajoutées après la passe
d'amortissement ; **leurs gains restent à chiffrer sur device** avec le protocole
ci-dessous.

## Budget par image — diagnostic initial

Décomposition obtenue en désactivant chaque passe (interrupteurs `AETHER_PERF_NO*`,
cf. « Méthode »), **avant** la refonte de l'amortissement (baseline 16 ips ≈ 62 ms) :

| Passe coupée | FPS obtenu | Coût isolé (≈) | Note |
|---|---|---|---|
| Nuage (`NOCLOUD`) | 55 | **~44 ms** | de loin le poste dominant |
| Ciel (`NOSKY`) | 23 | ~19 ms | raymarch atmosphérique par pixel |
| Mer (`NOSEA`) | 18 | ~7 ms | raymarch de hauteur sous l'horizon |

> Les coûts ne s'additionnent pas linéairement (passes partiellement recouvertes
> sur le GPU). Le composite plein écran, lui, n'a jamais émergé comme un poste
> significatif (~1–2 ms : un sample + blend par pixel, borné bande passante).

**Constat clé** : repos = mouvement = 15 ips. L'amortissement temporel 2×2
d'origine ne gagnait **rien** — voir l'encadré ci-dessous.

## Optimisations en place

### 1. Demi-résolution
Toutes les passes lourdes (nuage, ciel, mer, god rays) sont rendues **hors écran
à demi-résolution** (¼ des pixels), puis agrandies à la composition. RGBA16Float
HDR pour préserver la plage avant tonemap.

### 2. Amortissement temporel par **compute compact**
Au repos, seul **¼ des pixels** (cellule 2×2 active) est raymarché par frame ; le
reste réutilise une cible persistante. Combiné à la demi-rés → **~1/16** du coût
raymarch par frame à l'arrêt. Appliqué au **nuage** (`cloud_kernel`) et à la
**radiance du ciel** (`sky_radiance_kernel`). En mouvement, `stride = 1` →
rafraîchissement complet (le rayon sous chaque pixel change, l'historique est
invalide).

> #### 🪤 Le piège résolu — divergence SIMD
> La version d'origine faisait l'amortissement dans **une passe fragment plein
> écran** : ¾ des pixels sortaient tôt (`return history`), ¼ raymarchaient. Mais
> le GPU exécute les fragments par groupes SIMD (quads 2×2, warps plus larges) :
> dans **chaque** quad 2×2, exactement 1 pixel raymarche → **chaque warp** contient
> un pixel lent → toute la durée du warp = celle du pixel qui marche. Les ¾ qui
> sortent tôt **attendent** quand même. **Gain réel : zéro** (repos = mouvement).
>
> La correction : raymarcher la cellule active dans un **compute kernel compact**
> qui écrit aux positions dispersées `gid·stride + offset`. Au repos `stride = 2`,
> on ne **lance** que ¼ des threads, et **tous** font du vrai travail — plus de
> divergence. C'est ce qui débloque le vrai 4×. Élimine aussi le ping-pong et la
> texture d'historique (la cible persistante accumule).
>
> Bonus mesuré : le compute est aussi plus efficace **à plein régime** (mouvement
> 15→22), la rastérisation du triangle plein écran en moins.

### 3. Mer **non amortie** (à dessein)
La passe ciel+mer rend aussi la **mer animée** (les vagues bougent avec le temps,
caméra immobile). L'amortir saccaderait les vagues au repos. Donc seule la
**radiance du ciel** est amortie (lente) ; la passe ciel+mer reste **plein
régime** et ne fait que **lire le cache** `skyAccum` pour le ciel. C'est le
compromis « amortir le lent, garder l'animé fluide ».

### 4. Réduction des pas de la mer
`SEA_NUM_STEPS` 6 → **4** (pas de la trace de hauteur), `SEA_ITER_FRAGMENT` 4 → **3**
(octaves de la normale). `SEA_ITER_GEOMETRY = 2` (trace) inchangé. Attaque
directement les ~7 ms de mer. À caler par capture (qualité de houle vs coût).

### 5. Upscale **MetalFX** spatial
Le composite est rendu en **demi-résolution** (lectures 1:1 des cibles), puis
`MTLFXSpatialScaler` agrandit ×2 vers la résolution native — upscale edge-aware
(bords de nuages / horizon / disque solaire plus nets que le bilinéaire). Repli
bilinéaire automatique là où MetalFX est absent (**simulateur**, devices non
supportés, échec de création) ; le workflow de vérif par capture simulateur reste
valide via ce repli. Knob DEBUG `AETHER_SCALE` (forcer le repli / tester une
échelle interne ≠ ½). Mode couleur `.perceptual` (contenu tonemappé
display-referred). Détail : [`PIPELINE.md`](PIPELINE.md) « Upscale MetalFX ».

> **Mise en garde perf** : MetalFX **spatial** (Phase 1) est essentiellement un
> gain de **qualité**, pas de perf — le composite qu'il remplace ne pesait que
> ~1–2 ms, que le coût du scaler re-dépense. Le vrai gain perf de MetalFX serait
> de rendre **sous** la demi-rés (Phase 2 temporal, cf. pistes). À surveiller : le
> motif d'amortissement 2×2 agrandi par un filtre non linéaire peut **fourmiller**
> aux bords au repos — vérifier sur device (le bilinéaire, lui, lisse ce motif).

## Méthode de mesure (reproductible)

1. **Build Release** (les chiffres d'un build Debug ne valent rien) avec le
   harnais DEBUG compilé : `xcodebuild … -configuration Release …
   SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG'`.
2. **Installer + lancer** sur device avec une scène déterministe :
   `xcrun devicectl device process launch --device <id> --environment-variables
   '{"AETHER_SHOT":"noon:13:shown:perf"}' io.github.glandais.aether`.
3. **Lire l'overlay FPS** à l'écran (`DebugHUD`, badge à gauche) — ips + ms.
4. **Deux régimes** : téléphone **immobile** (amortissement actif) puis **en
   panoramique continu** (`stride = 1`, pire cas). L'écart valide l'amortissement.
5. **Isoler une passe** : relancer en ajoutant `AETHER_PERF_NOSKY` / `NOSEA` /
   `NOCLOUD` = `1` (sans rebuild). La différence de FPS attribue le coût.
6. **GPU capture Xcode** sur device pour des timings par encodeur précis (utile
   pour confirmer le coût réel du composite/scaler et l'overlap des passes).

Référence complète de l'outillage DEBUG : `CLAUDE.md` « Outillage DEBUG ».

## Pistes d'amélioration (par ROI décroissant)

### A. Réduire les pas du raymarch **nuage** — *facile, fort impact*
Le nuage reste le poste dominant. Aujourd'hui `mix(96, 54)` pas par coquille
(`Cloud.metal`), **× jusqu'à 4 coquilles**, soit ~3× le coût d'une seule coquille
de la référence. Plus `kLightSteps = 6` par échantillon dense (marche de lumière).
Leviers, calables par capture :
- pas de vue par coquille `mix(96,54)` → p.ex. `mix(64,40)` ;
- `kLightSteps` 6 → 4 ;
- early-out plus agressif (`break` sur transmittance, `continue` sur couverture
  nulle déjà en place — vérifier les seuils).
1 ligne chacun, aucun risque architectural, simulateur intact.

### B. Réduire / précalculer le **ciel** — *moyen*
`computeSkyRadiance` = `PRIMARY_STEPS = 16` × `LIGHT_STEPS = 8` = 128 itérations
par pixel. Déjà **amorti** (¼ des pixels), mais chaque pixel actif reste cher.
- **Réduction directe** : 16/8 → 8/4 (×4 sur la passe ciel). Risque : banding au
  ras de l'horizon / autour du soleil.
- **LUT atmosphérique** (Hillaire 2020) : le ciel = fonction de (élévation, angle
  soleil) → précalcul dans une petite texture 2D, échantillonnée au lieu de
  raymarchée. Le ciel devient quasi gratuit ; plus de travail, et rend
  l'amortissement du ciel superflu. La meilleure cible si on veut un ciel
  « gratuit ».

### C. **MetalFX temporal** (Phase 2) — *gros gain perf, gros risque*
Rendre **sous** la demi-résolution (⅓ ou ¼) et laisser `MTLFXTemporalScaler`
reconstruire à qualité quasi native. C'est là que MetalFX paie réellement en
perf (contrairement au spatial). Exige : **motion vectors** (analytiques possibles
pour une caméra en rotation pure), **jitter** sous-pixel, et **remplace
l'amortissement compact maison**. Risque principal : **ghosting volumétrique**
(les nuages/mer ne sont pas des surfaces opaques avec depth nette). À prototyper
et juger sur device avant d'investir.

### D. **Frame interpolation** (Phase 3, iOS 26) — *conditionnel*
`MTLFXFrameInterpolator` : 30→60, ou 60→120 sur la dalle ProMotion du 13 Pro.
Réutilise les motion vectors de la Phase 2. Ajoute de la latence ; à réserver à
un mode « lecture » fluide. Dépend de la Phase 2.

### E. Micro-optimisations — *faible impact, faible risque*
- **God rays** : passe demi-rés supplémentaire ; mesurer son coût isolé (pas de
  toggle dédié aujourd'hui — en ajouter un). Possible de la fusionner ou de la
  désactiver quand le soleil est sous l'horizon / couvert.
- **Composite** : déjà négligeable ; rien à gagner sans la Phase 2.
- **Atlas de couverture** : la réconciliation tourne chaque frame (`CoverageBaker`)
  — vérifier qu'elle ne re-stampe pas inutilement (delta par calque déjà en place).
- **`preferredFramesPerSecond`** : fixé à 60 ; sur ProMotion, un plancher adaptatif
  (ex. 30 quand statique) économiserait la batterie sans perte perçue.

## Pièges & notes

- **`dispatchThreads` (threadgroups non-uniformes)** n'écrivait pas correctement
  selon le GPU (constaté sur le simulateur lors de la refonte) → utiliser
  **`dispatchThreadgroups`** + garde de bornes dans le kernel.
- **Cibles persistantes** (`cloudAccum`, `skyAccum`) : un flag *dirty* force un
  refresh complet (`stride = 1`) à la (ré)allocation, sinon les pixels non encore
  écrits composent du bruit non initialisé.
- **Accès main-thread** : `Renderer.draw` (delegate `MTKView`) tourne sur le main
  thread ; l'écriture du FPS vers l'overlay `@MainActor` passe par
  `MainActor.assumeIsolated`.
- **Simulateur ≠ device** : fluide sur simulateur (GPU Mac) ne dit **rien** de la
  perf device ; et MetalFX y est en repli bilinéaire. Toujours conclure sur device.
