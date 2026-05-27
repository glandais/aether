# Bibliographie — rendu de nuages volumétriques

> Références algorithmiques pour le pipeline de rendu d'Aether (raymarching de
> nuages volumétriques en Metal). Chaque entrée indique son apport et l'étape du
> pipeline qu'elle informe (voir `CLAUDE.md` → « Pipeline de rendu »).

Repère de lecture rapide : commencer par **Schneider 2015** (le canon du
domaine), puis **Hillaire 2016** pour le scattering physique, et garder le
**gist pixelsnafu** comme méta-index toujours à jour.

---

## 1. Articles & présentations fondateurs

### Schneider & Vos — *The Real-Time Volumetric Cloudscapes of Horizon: Zero Dawn* (SIGGRAPH 2015)

Le texte de référence du domaine. Décrit le système **Nubis** de Guerrilla
Games : modélisation par *coverage / height / type maps*, bruit **Perlin-Worley**
pour le détail, raymarching optimisé, et le modèle d'éclairage
Beer-Lambert + Henyey-Greenstein + effet *powder* (assombrissement des bords
éclairés de face). Rendu sous 2 ms sur PS4.

- Slides : https://advances.realtimerendering.com/s2015/The%20Real-time%20Volumetric%20Cloudscapes%20of%20Horizon%20-%20Zero%20Dawn%20-%20ARTR.pdf
- Index du cours : https://advances.realtimerendering.com/s2015/
- Version chapitre : Andrew Schneider, « Real-Time Volumetric Cloudscapes »,
  *GPU Pro 7*, CRC Press, 2016.
- **Étapes Aether : 2, 3, 4, 5.**

### Schneider — *Nubis: Authoring Real-Time Volumetric Cloudscapes with the Decima Engine* (SIGGRAPH 2017)

Suite production-oriented : passage de prototype à outil de jeu. Authoring de
cloudscapes à l'échelle régionale, animation/transitions, intégration
atmosphérique, optimisations. Affine le modèle de densité et le *cloud
modeling*.

- Slides : https://advances.realtimerendering.com/s2017/Nubis%20-%20Authoring%20Realtime%20Volumetric%20Cloudscapes%20with%20the%20Decima%20Engine%20-%20Final%20.pdf
- Page Guerrilla : https://www.guerrilla-games.com/read/nubis-authoring-real-time-volumetric-cloudscapes-with-the-decima-engine
- **Étapes Aether : 3, 4.**

### Schneider — *Nubis, Evolved* (SIGGRAPH 2022) & *Nubis Cubed* (2023)

Évolution PS5 / *Horizon Forbidden West* : nuages traversables, environnements,
VFX (superstorms à éclairage interne), améliorations qualité/perf. *Nubis
Cubed* pousse vers le rendu volumétrique de formes arbitraires.

- *Nubis, Evolved* : https://www.guerrilla-games.com/read/nubis-evolved
- *Nubis Cubed* (PDF) : https://d3d3g8mu99pzk9.cloudfront.net/AndrewSchneider/Nubis%20Cubed.pdf
- Publications de l'auteur : https://sites.google.com/view/vonschneidz/publications
- **Étapes Aether : 5, 7** (référence avancée, à consulter pour la perf).

### Hillaire — *Physically Based Sky, Atmosphere & Cloud Rendering in Frostbite* (SIGGRAPH 2016)

Le pendant « physique » de Schneider. Cadre rigoureux du transport radiatif :
diffusion simple/multiple, couplage ciel ↔ atmosphère ↔ nuages, *time of day*
dynamique. Indispensable pour l'étape scattering et l'intégration soleil/lune.

- Page Frostbite : https://www.ea.com/frostbite/news/physically-based-sky-atmosphere-and-cloud-rendering
- Slides 2020 (version condensée) : https://blog.selfshadow.com/publications/s2020-shading-course/hillaire/s2020_pbs_hillaire_slides.pdf
- **Étapes Aether : 5, 8, 9.**

### Hillaire — *A Scalable and Production Ready Sky and Atmosphere Rendering Technique* (CGF / EGSR 2020)

Diffusion atmosphérique du sol à l'espace sans LUT de haute dimension. Pertinent
pour le fond de ciel et la lumière ambiante alimentant les nuages.

- Wiley : https://onlinelibrary.wiley.com/doi/abs/10.1111/cgf.14050
- **Étape Aether : 8, 9** (couleur du ciel selon l'heure/position).

### Häkkinen — *Optimisations for Real-Time Volumetric Cloudscapes* (2016)

Mémoire centré sur les optimisations de la méthode Schneider : *cone sampling*
pour l'éclairage, *early-out*, stratégies d'échantillonnage adaptatif.

- arXiv : https://arxiv.org/pdf/1609.05344
- **Étape Aether : 7.**

### Häggström — *Real-Time Rendering of Volumetric Clouds* (mémoire, Umeå, 2018)

Implémentation détaillée et pédagogique (moteur Stingray) : génération des
bruits 2D/3D Perlin+Worley, fonction de remap pour combiner les bruits, modèle
de densité, raymarching. Excellent guide pas-à-pas pour reproduire le pipeline.

- Semantic Scholar : https://www.semanticscholar.org/paper/Real-time-rendering-of-volumetric-clouds-H%C3%A4ggstr%C3%B6m/89e9153a091889c584df034a953a0eff4de45ee9
- **Étapes Aether : 2, 3, 4.**

### Patapom (Pomerleau) — *Real-Time Volumetric Rendering Course Notes* (Revision 2013)

Notes de cours sur le transport radiatif appliqué au temps réel : radiance,
extinction, scattering, *volumetric shadowing*. Bonne base théorique avant
d'aborder Beer-Lambert / Henyey-Greenstein.

- PDF : https://patapom.com/topics/Revision2013/Revision%202013%20-%20Real-time%20Volumetric%20Rendering%20Course%20Notes.pdf
- **Étape Aether : 5.**

---

## 2. Diffusion & éclairage (étape 5)

### Beer-Lambert & ray marching — Scratchapixel

Tutoriel rigoureux et gratuit sur le volume rendering par ray marching :
transmittance (loi de Beer), absorption/scattering, ordre d'intégration correct.

- https://www.scratchapixel.com/lessons/3d-basic-rendering/volume-rendering-for-developers/ray-marching-get-it-right.html

### Fonction de phase de Henyey-Greenstein

Modèle de l'anisotropie de la diffusion (g ≈ 0,8 pour les nuages). Souvent
combiné en double-lobe (forward + backward) pour le rendu de nuages.

- Wikipédia (formule + dérivations) : https://en.wikipedia.org/wiki/Henyey%E2%80%93Greenstein_phase_function

### Wallis — *Volumetric Rendering* (série de blog)

Décortique le pipeline Schneider côté implémentation : Beer's law, *light
marching* pour l'auto-ombrage, Henyey-Greenstein, *powder effect*.

- https://wallisc.github.io/rendering/2020/05/02/Volumetric-Rendering-Part-1.html

---

## 3. Génération de bruit procédural (étape 3)

### Perlin-Worley & textures de volume

La combinaison Perlin (basse fréquence, structure) + Worley/cellular (érosion,
détail floconneux) est le standard depuis Schneider 2015. Voir §1 (Schneider,
Häggström) pour les recettes de remap. Le bruit doit être *tileable* en 3D et
précalculé en compute shader.

- Bitsquid (dev blog Stingray) — *Volumetric Clouds* : http://bitsquid.blogspot.com/2016/07/volumetric-clouds.html

### Quilez — *Dynamic Clouds* & articles bruit/SDF

Technique historique (2002) d'offset de textures de bruit précalculées,
adaptée au GPU. Plus généralement, les articles d'Inigo Quilez sont la
référence pour le bruit, le fBm et le ray marching de SDF.

- *Dynamic Clouds* : https://iquilezles.org/articles/dynclouds/
- Index articles : https://iquilezles.org/articles/

---

## 4. Composition par profondeur (étape 6)

L'étape 6 a deux faces : (a) **obtenir** une depth map du paysage, et (b) s'en
servir pour **occlure correctement** les nuages raymarchés par le relief.

### a. Source de la depth map

Pour Aether, la profondeur du paysage vient soit du LiDAR (photos ARKit), soit
d'une estimation monoculaire (galerie curée / photo sans LiDAR via CoreML).

- **ARKit — `ARFrame.sceneDepth` / `ARDepthData`** : `depthMap` (mètres) +
  `confidenceMap`, 60 Hz, devices LiDAR uniquement (vérifier
  `supportsFrameSemantics(_:)`). `smoothedSceneDepth` pour réduire le flicker.
  - https://developer.apple.com/documentation/arkit/arframe/scenedepth
  - https://developer.apple.com/documentation/arkit/ardepthdata
  - *Displaying a point cloud using scene depth* (sample) :
    https://developer.apple.com/documentation/ARKit/displaying-a-point-cloud-using-scene-depth
- **Depth Anything V2** (NeurIPS 2024) — depth monoculaire, modèle de
  fondation. Variante *metric depth* (mètres) utile pour positionner le relief.
  Small en Apache-2.0 (convertible CoreML) ; Base/Large en CC-BY-NC-4.0
  (vérifier la licence avant embarquement).
  - Repo officiel : https://github.com/DepthAnything/Depth-Anything-V2
  - Page projet : https://depth-anything-v2.github.io/
  - V1 (CVPR 2024) : https://github.com/LiheYoung/Depth-Anything

> La profondeur monoculaire est *relative* (à recaler en échelle), bruitée et
> sans bord net. Pour la composition, la traiter comme un masque d'occlusion
> tolérant (cf. soft particles ci-dessous), pas comme une géométrie exacte.

### b. Occlusion & composition

- **Early ray termination à la profondeur de scène** : pendant le raymarching,
  borner le rayon par la distance lue dans la depth map (reconstruite en
  position monde via l'inverse des matrices vue/projection). Le nuage ne
  s'accumule pas derrière le relief. Häkkinen (§1) décrit l'arrêt anticipé.
- **Soft particles** : atténuer l'opacité du nuage quand sa profondeur approche
  celle de la scène, pour éviter les arêtes franches d'intersection avec le
  relief. Le principe (différence de profondeur → falloff d'alpha) se transpose
  directement au raymarching.
  - Wolfire — *Soft Particles* (explication claire) : http://blog.wolfire.com/2010/04/Soft-Particles
  - Flax — *HOWTO: Make soft particles* : https://docs.flaxengine.com/manual/particles/tutorials/soft-particles.html
- **Aerial perspective / couplage profondeur ↔ atmosphère** : Hillaire 2016
  (§1) traite la composition des médias participatifs avec la scène opaque et
  l'extinction selon la distance — la base physique de l'étape 6.

---

## 5. Code d'exemple

| Projet | Techno | Notes |
|---|---|---|
| [clayjohn/godot-volumetric-cloud-demo](https://github.com/clayjohn/godot-volumetric-cloud-demo) | Godot sky shader | Implémentation lisible basée Schneider HZD. [Shader direct](https://github.com/clayjohn/godot-volumetric-cloud-demo/blob/main/clouds.gdshader). |
| [clayjohn/godot-volumetric-cloud-demo-v2](https://github.com/clayjohn/godot-volumetric-cloud-demo-v2) | Godot 4.2+ compute | V2 avec compute shaders (génération bruit) + sky shader. |
| [clayjohn/realtime_clouds](https://github.com/clayjohn/realtime_clouds) | OpenGL/C++ | Expérimentation visant le matériel bas de gamme. |
| [adrianderstroff/realtime-clouds](https://github.com/adrianderstroff/realtime-clouds) | OpenGL/Go | Reproduction du renderer Horizon: Zero Dawn. |
| [AmanSachan1/Meteoros](https://github.com/AmanSachan1/Meteoros) | Vulkan | Cloudscape temps réel d'après Decima/Nubis. |
| [iamzhai/RealTimeVolumetricClouds](https://github.com/iamzhai/RealTimeVolumetricClouds) | Unity | Compilation de méthodes issues de la littérature. |

> Note plateforme : ces dépôts sont en GLSL/HLSL/Vulkan, pas en Metal Shading
> Language. Les transposer à MSL est direct mais manuel (textures 3D, compute,
> `[[stage_in]]`). Pour Metal, s'appuyer sur les algorithmes ci-dessus et sur la
> doc Apple MetalKit/MTLComputeCommandEncoder.

### Shadertoy (prototypage shader rapide)

- Inigo Quilez — *Clouds* : https://www.shadertoy.com/view/XslGRr
- Reinder Nijhoff — *Himalayas* : https://reindernijhoff.net/shadertoy/MdGfzh/
- robobo1221 — *Real Time PBR Volumetric Clouds* (rechercher sur shadertoy.com)

---

## 6. Méta-ressources (index tenus à jour)

- **Sébastien Hillaire / pixelsnafu — *Useful Resources for Rendering Volumetric Clouds*** (gist de référence, la liste la plus complète) :
  https://gist.github.com/pixelsnafu/e3904c49cbd8ff52cb53d95ceda3980e
- *Advances in Real-Time Rendering* (SIGGRAPH courses, index annuel) :
  https://advances.realtimerendering.com/
- Wayline — *Volumetric Rendering Resource Reference Sheet* :
  https://www.wayline.io/blog/volumetric-rendering-complete-resource-reference-sheet
- Maxime Heckel — *Real-time dreamy Cloudscapes with Volumetric Raymarching*
  (tutoriel WebGL pédagogique) :
  https://blog.maximeheckel.com/posts/real-time-cloudscapes-with-volumetric-raymarching/

---

## 7. Données astronomiques externes

### Yale Bright Star Catalog (BSC5) — étoiles dessinées dans le ciel

- Hoffleit & Warren — *Bright Star Catalogue, 5th Revised Ed.* (1991), distribué
  par l'Astronomical Data Center / Harvard :
  http://tdc-www.harvard.edu/catalogs/bsc5.html
- ~9 110 étoiles à largeur fixe (HR, position B1900/J2000, Vmag, indice B-V…).
  Aether en extrait position J2000 + Vmag + B-V → binaire compact `bsc5.bin`
  (`scripts/build_star_catalog.py`), résolu en directions monde par temps sidéral
  local (GMST, Meeus chap. 12) + latitude — `Aether/Domain/StarCatalog.swift`.
- Rendu : points additifs *passifs* (sans éclairage), teintés par B-V, night-gated
  et occlus par les nuages — `Aether/Rendering/Shaders/Stars.metal`.

---

## Correspondance pipeline Aether → références prioritaires

| Étape (CLAUDE.md) | Références à lire |
|---|---|
| 2. Raymarching nuage analytique | Schneider 2015, Häggström, Quilez, Scratchapixel |
| 3. Volume textures, bruit Perlin-Worley | Schneider 2015/2017, Häggström, Bitsquid |
| 4. Pinceau → champ de densité | Schneider 2017 (authoring), Häggström |
| 5. Scattering (Beer-Lambert + HG) | Hillaire 2016, Patapom, Wallis, Scratchapixel |
| 6. Composition avec depth map | ARKit sceneDepth, Depth Anything V2, soft particles, Hillaire 2016 |
| 7. Half-res + temporal reprojection | Häkkinen, Nubis Evolved |
| 8. Position soleil/lune dynamique | Hillaire 2016 & 2020 |
| 9. Init depuis météo | Hillaire 2016 (couplage atmosphère/nuages) |
