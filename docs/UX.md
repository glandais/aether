# UX — Aether

> Description de l'expérience utilisateur telle qu'elle existe aujourd'hui.

---

## Navigation principale

L'app démarre sur la galerie. Sélectionner un paysage (ou ouvrir un fichier `.aether`) ouvre le canvas plein écran. Un bouton retour (chevron haut-gauche) revient à la galerie. Transition : fondu enchaîné `easeInOut(0.3s)`.

```
RootView
├── context == nil  →  GalleryView
└── context != nil  →  CanvasView
```

---

## Galerie (`GalleryView`)

Grille adaptive (colonnes ≥ 150 pt, `LazyVGrid`) de paysages curés. Chaque vignette est un dégradé procédural (sol → horizon → ciel), titre en bas à gauche.

**Paysages curés (4) :**

| Titre | Lieu | Heure | Météo |
|---|---|---|---|
| Crépuscule | Paris | 19 h 15 | Partiellement nuageux |
| Aube | Kyoto | 20 h 00 | Dégagé |
| Heure bleue | Reykjavik | 22 h 30 | Couvert |
| Plein midi | Sydney | 02 h 00 | Partiellement nuageux |

**Barre de navigation :** titre « Aether » + bouton dossier (icône `folder`) pour importer un fichier `.aether`.

**Import :** `.fileImporter` limité au type `io.github.glandais.aether.scene`. Succès → ouvre le canvas avec l'état restauré. Échec → alerte localisée.

---

## Canvas (`CanvasView`)

Fond noir plein écran. `MTKView` centré avec éventuellement des bandes (letterbox) si le paysage importé a un ratio non standard.

### Chrome (contrôles UI)

Tous les contrôles sont regroupés dans une couche superposée au rendu. Un bouton unique (icône `slider.horizontal.3`) les cache/révèle — `showOptions` — pour dégager le ciel.

**Portrait :** palette en colonne verticale, droite écran.  
**Paysage (hauteur compacte) :** palette en rangée horizontale, haut écran.

---

## Palette d'outils (boutons-bulles)

Chaque bouton : cercle 44 pt, `.ultraThinMaterial`, icône 18×18 pt, teinté quand actif.

| Bouton | Icône | Rôle |
|---|---|---|
| Options | `slider.horizontal.3` | Afficher/masquer tous les contrôles |
| Rotation | `arrow.up.and.down.and.arrow.left.and.right` | Basculer mode rotation / peinture |
| Pinceau | `paintbrush.pointed` | Activer le mode peinture (révèle le panneau Peinture) |
| Plus | `ellipsis` | Ouvrir le panneau « Plus » |

Un seul panneau flottant peut être ouvert à la fois. Transition : fondu + scale(0.95).

Le panneau Peinture n'a pas de pastille dédiée : il s'affiche de lui-même tant que le mode peinture est actif et les contrôles visibles. Seul « Plus » est un panneau explicitement ouvert/fermé.

---

## Gestes sur le canvas

### Mode peinture (défaut)

- **Glisser** → déposer un trait sur le calque actif.
- Un trait est une série de points 2D normalisés [0,1]², décimés (espacement min. 0.012).
- La pose caméra est capturée au début du trait (`StrokeCamera`) pour projeter la peinture dans la coquille sphérique correspondante.

### Mode rotation (`isRotating = true`)

- **Glisser gauche/droite** → yaw (pan horizontal, non borné).
- **Glisser haut/bas** → pitch (inclinaison verticale, borné ±80°).
- **Pincer (deux doigts)** → zoom (FOV de 25° à 100°).
- Ancre de rotation mémorisée au début du glisser pour éviter le saut.

---

## Panneau Peinture

Carte flottante `.ultraThinMaterial`, apparaît quand le mode peinture est actif et les contrôles visibles (pas de bascule dédiée). Réunit tout le geste de dessin sur une seule carte, de haut en bas : choix du calque, opacité, réglages de pinceau.

**Calques** — les trois étages, par altitude décroissante :

| Calque | Altitude | Genre |
|---|---|---|
| Cirrus | Élevée | Fins, fibreux |
| Altocumulus | Moyenne | Floconneux |
| Cumulus | Basse | Épais, imposants |

Par calque :
- Grand cercle indicateur (plein si actif, vide sinon) — sélectionne le calque qui reçoit la peinture.
- Nom du calque — appuyer sélectionne le calque (ses réglages de pinceau sont déjà sur la même carte, plus bas).
- Icône œil (`eye`) — masquer/révéler, affiché seulement si le calque a des traits.

**Opacité** (filet de séparation au-dessus) — curseur (icône `circle.lefthalf.filled`, plage 0–1) du calque sélectionné ; désactivé si le calque est vide.

**Pinceau** (filet de séparation au-dessus) — réglages globaux, appliqués au calque actif :

| Réglage | Icône | Plage |
|---|---|---|
| Rayon | `smallcircle.filled.circle` | 0,03 – 0,25 |
| Douceur | `drop` | 0 (bord dur) – 1 (très diffus) |

**Undo / Redo / Clear :** pastilles de la palette (hors carte), affichées uniquement quand des modifications existent (`hasEdits`).

---

## Barre de temps

Capsule `.ultraThinMaterial`, centrée en bas, largeur max. 520 pt.

| Élément | Détail |
|---|---|
| Curseur heure | 0–24 h, continu |
| Icône soleil/lune | Soleil si jour, lune+étoiles si nuit |
| Bouton rembobiner (`backward.fill`) | Avance continue vers l'arrière |
| Bouton avancer (`forward.fill`) | Avance continue vers l'avant |
| Multiplicateur vitesse | Cycle 1× → 2× → 4× → 8× → 16× (1× ≈ 0,25 h/s) |
| Affichage HH:mm | Police chasse fixe, droite |

L'avance continue utilise `ContinuousClock` (indépendant du rendu), avec un plafond 0,5 s/frame pour absorber le retour de fond.

---

## Panneau « Plus »

Carte flottante verticale `.ultraThinMaterial`.

**Centrer sur :**
- Bouton Soleil (`sun.max`) — désactivé si le soleil est sous l'horizon.
- Bouton Lune (`moon.stars`) — désactivé si la lune est sous l'horizon.
- Appuyer → ferme le panneau, réoriente la caméra sur l'astre.

**Position & Heure :**
- Date : sélecteur jour/mois/an (style compact, calendrier GMT).
- Coordonnées : affichage `48,9°N, 2,4°E` + bouton crayon → ouvre `LocationPickerView`.
- Bouton « Ici & maintenant » (icône `location.fill`) : résout GPS + fuseau horaire, met à jour les trois (lieu/date/heure). Spinner pendant la résolution.

**Éphémérides :**
- Bouton icône `info.circle` → fiche modale (`.sheet`) avec levers/couchers du soleil et de la lune, phase lunaire + pourcentage d'illumination, gestion des états polaires (« toujours levé » / « toujours couché »).

**Enregistrer :**
- Bouton `square.and.arrow.down` → `.fileExporter`, nom de fichier = titre du paysage, format `.aetherScene`.

---

## Sélecteur de lieu (`LocationPickerView`)

Carte MapKit plein écran. Curseur centré (pin central fixe, carte défilante). Bouton « Ma position » (icône `location`) demande CoreLocation. Boutons Annuler / Confirmer.

---

## Persistance (`.aether`)

Format : JSON + PNG embarqué (autonome, partageable). Version actuelle : **v2**. Les fichiers v1 sont rejetés avec une alerte.

**Données sauvegardées :**
- Calques (traits + paramètres de rendu)
- Pose caméra (yaw, pitch, FOV)
- Réglages du pinceau (rayon, douceur)
- Overrides heure, date, coordonnées, fuseau horaire
- Image du paysage (PNG intégré)

---

## HUD de debug (DEBUG uniquement)

Coin haut-gauche, police chasse fixe, fps + ms/frame. Non interactif. Absent des builds Release.

---

## Accessibilité

- Tous les boutons ont un `accessibilityLabel` localisé.
- Les curseurs exposent `accessibilityValue` (ex. « 3× »).
- Les bascules d'état portent `.accessibilityAddTraits(.isSelected)` quand actives.
