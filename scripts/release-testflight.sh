#!/usr/bin/env bash
#
# release-testflight.sh — publie automatiquement une nouvelle version sur TestFlight.
#
# Auto-bump du patch (MARKETING_VERSION x.y.z → x.y.(z+1)) ET du numéro de build
# (monotone croissant sur toute l'app), puis archive → export → upload →
# distribution au groupe interne, en une commande. Pas de changelog calculé :
# la note « What to Test » est un simple horodatage de version (surchageable).
#
# Source de vérité de la version : project.yml (le .xcodeproj est régénéré par
# XcodeGen, donc on ne touche jamais le .pbxproj — agvtool / `asc xcode version`
# seraient écrasés au prochain `xcodegen generate`).
#
# Usage :
#   scripts/release-testflight.sh
#
# Variables d'environnement (optionnelles) :
#   ASC_APP_ID      id App Store Connect           (défaut : 6773940359)
#   TF_GROUP        groupe TestFlight (nom ou id)  (défaut : "Internal Testers")
#   TEST_NOTES      note « What to Test » fr-FR    (défaut : "Version <v> (build <n>).")
#   RELEASE_COMMIT  =1 → commit le bump de version sur la branche courante
#
set -euo pipefail

# --- Réglages -----------------------------------------------------------------
ASC_APP_ID="${ASC_APP_ID:-6773940359}"
TF_GROUP="${TF_GROUP:-Internal Testers}"
SCHEME="Aether"
PROJECT="Aether.xcodeproj"
PLATFORM="IOS"

# Se placer à la racine du dépôt (le script vit dans scripts/).
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Aether.xcarchive"
EXPORT_DIR="$BUILD_DIR/AetherExport"
IPA="$EXPORT_DIR/Aether.ipa"
EXPORT_OPTS="$ROOT/scripts/ExportOptions.plist"

echo "▸ Release TestFlight — app $ASC_APP_ID, groupe « $TF_GROUP »"

# --- 1. Calculer la nouvelle version ------------------------------------------
cur_version="$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
cur_build="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"

# Patch + 1 (x.y.z → x.y.(z+1)).
IFS='.' read -r major minor patch <<<"$cur_version"
new_version="${major}.${minor}.$((patch + 1))"

# Numéro de build monotone : max(local, max ASC) + 1.
asc_max="$(asc builds list --app "$ASC_APP_ID" --platform "$PLATFORM" --limit 200 --output json 2>/dev/null \
  | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    n=[int(b['attributes'].get('version') or 0) for b in d.get('data',[])]
    print(max(n) if n else 0)
except Exception:
    print(0)" )"
local_build=$(( ${cur_build:-0} ))
base=$(( asc_max > local_build ? asc_max : local_build ))
new_build=$(( base + 1 ))

echo "▸ Version  : $cur_version (build $cur_build)  →  $new_version (build $new_build)"

# --- 2. Écrire project.yml + régénérer ----------------------------------------
# macOS sed (-i '') ; on cible précisément les deux clés.
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*/\1\"$new_version\"/" project.yml
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*).*/\1\"$new_build\"/" project.yml
echo "▸ project.yml mis à jour ; régénération XcodeGen"
xcodegen generate >/dev/null

# --- 3. Archiver --------------------------------------------------------------
echo "▸ Archive (Release, signature auto)"
xcodebuild clean archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR/dd" -allowProvisioningUpdates \
  >/dev/null
echo "  ✓ archive ok"

# --- 4. Exporter l'IPA --------------------------------------------------------
echo "▸ Export IPA App Store"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" -allowProvisioningUpdates \
  >/dev/null
echo "  ✓ $IPA"

# --- 5. Publier sur TestFlight (upload + wait + distribution + note) ----------
notes="${TEST_NOTES:-Version $new_version (build $new_build).}"
echo "▸ Upload + distribution TestFlight (attente du traitement)…"
asc publish testflight \
  --app "$ASC_APP_ID" \
  --ipa "$IPA" \
  --group "$TF_GROUP" \
  --wait \
  --test-notes "$notes" \
  --locale fr-FR

# --- 6. Commit optionnel du bump ----------------------------------------------
if [ "${RELEASE_COMMIT:-0}" = "1" ]; then
  echo "▸ Commit du bump de version"
  git add project.yml
  git commit -m "build(ios): version $new_version (build $new_build)"
fi

echo "✅ $new_version (build $new_build) publiée sur TestFlight (« $TF_GROUP »)."
echo "   project.yml a été bumpé${RELEASE_COMMIT:+ et commité}."
