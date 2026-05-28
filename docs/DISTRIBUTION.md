# Distribution App Store / TestFlight

L'app est distribuée via le CLI **`asc`** (auth par clé d'équipe dans le
trousseau). Le pipeline build → upload → TestFlight est rodé ; la première
release publique App Store reste à faire (métadonnées, captures, App Privacy).
Skills `asc-*` pour l'outillage.

## Coordonnées App Store Connect

- **App ID (ASC)** : `6773940359`
- **Nom de fiche store** : « **Aether Painter** » (« Aether » seul est déjà pris
  globalement sur l'App Store). Le nom d'écran d'accueil reste « Aether »
  (`CFBundleDisplayName`), indépendant du nom de fiche.
- **Bundle id** : `io.github.glandais.aether` · **UGS/SKU** : idem · **locale
  primaire** : `fr-FR` · **équipe** : `7Q49262697`
- Free, pas d'IAP, pas de collecte de données (localisation on-device seulement).
- Catégorie store visée : **Graphics & Design**.

## Réglages `project.yml` exigés par la distribution

- `UIRequiresFullScreen: YES` — **obligatoire** : la cible est universelle
  (iPhone+iPad) et ne déclare qu'un sous-ensemble d'orientations
  (portrait + paysage, **pas** portrait-renversé) ; sans ce flag, l'**ingestion
  App Store échoue silencieusement** sur **ITMS-90474** (« apps iPad doivent
  supporter toutes les orientations sauf si plein écran »). Le build n'apparaît
  alors jamais sur TestFlight. Vérifier l'erreur via `asc builds uploads list`,
  pas seulement `asc builds list` (qui reste vide en cas d'échec d'ingestion).
- `ITSAppUsesNonExemptEncryption: NO` — évite la question de conformité export à
  chaque build (chiffrement « exempt »).
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` : bumper avant chaque archive ;
  garder le numéro de build **monotone croissant** sur l'app entière.

## Release automatisée TestFlight

Pour publier une nouvelle build sur TestFlight en une commande :

```sh
scripts/release-testflight.sh
```

Le script (source de vérité = `project.yml`, jamais le `.pbxproj`) :

1. **auto-bump** le patch (`MARKETING_VERSION` x.y.z → x.y.(z+1)) **et** le numéro
   de build (monotone : `max(local, max ASC) + 1`), puis `xcodegen generate` ;
2. archive (Release, signature auto) puis exporte l'IPA
   (`scripts/ExportOptions.plist`, commité — `build/` est git-ignoré) ;
3. `asc publish testflight --wait` : upload + attente du traitement +
   distribution au groupe interne + note « What to Test ».

Pas de changelog calculé : la note est un simple horodatage `Version x.y.z
(build n)`. Variables d'environnement (optionnelles) :

| Var | Défaut | Rôle |
|---|---|---|
| `ASC_APP_ID` | `6773940359` | id App Store Connect |
| `TF_GROUP` | `Internal Testers` | groupe TestFlight (nom ou id) |
| `TEST_NOTES` | `Version <v> (build <n>).` | note « What to Test » fr-FR |
| `RELEASE_COMMIT` | `0` | `=1` → commit le bump sur la branche courante |

Le bump de `project.yml` n'est **pas** commité par défaut (mettre
`RELEASE_COMMIT=1` pour l'automatiser). Le flux manuel détaillé ci-dessous reste
valable pour le débogage.

## Flux complet manuel (release iOS)

```sh
# 1. Bumper version + build dans project.yml, puis régénérer
xcodegen generate

# 2. Archiver (signature auto, équipe 7Q49262697)
xcodebuild clean archive -project Aether.xcodeproj -scheme Aether \
  -configuration Release -archivePath build/Aether.xcarchive \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd \
  -allowProvisioningUpdates

# 3. Exporter l'IPA App Store (build/ExportOptions.plist : method app-store-connect)
xcodebuild -exportArchive -archivePath build/Aether.xcarchive \
  -exportPath build/AetherExport -exportOptionsPlist build/ExportOptions.plist \
  -allowProvisioningUpdates

# 4. Uploader puis vérifier que l'ingestion passe (≠ FAILED)
asc builds upload --app 6773940359 --ipa build/AetherExport/Aether.ipa
asc builds uploads list --app 6773940359 --output json   # state doit passer PROCESSING

# 5. Attendre que le build soit VALID
asc builds list --app 6773940359 --platform IOS --limit 5 --output table

# 6. Publier sur le groupe interne TestFlight + note « What to Test » (fr-FR)
asc builds add-groups --build-id <BUILD_ID> --group <GROUP_ID>
asc builds test-notes create --build-id <BUILD_ID> --locale fr-FR --whats-new "…"
# (si la note ressort vide, récupérer l'ID via test-notes list puis test-notes update)
```

Groupe interne TestFlight : « **Internal Testers** » (`isInternalGroup: true`,
les builds internes sautent la beta review). Testeur :
`gabriel.landais@gmail.com`.

## Reste à faire — release App Store publique

Captures d'écran (6,9″ iPhone obligatoire), métadonnées (description/mots-clés/
sous-titre), catégorie Graphics & Design, App Privacy « Données non collectées »,
prix gratuit + bootstrap des territoires, puis soumission. Le bloqueur
d'orientation iPad (ITMS-90474) est déjà réglé.
