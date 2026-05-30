#!/usr/bin/env bash
#
# verify.sh — contrôle qualité à lancer après toute modification de code.
#
# Enchaîne trois vérifications statiques, dans l'ordre du moins au plus coûteux :
#   1. SwiftLint        — style et garde-fous (mode --strict : tout warning bloque)
#   2. xcodebuild analyze — analyseur statique du compilateur (bugs, concurrence)
#   3. Periphery        — code mort (déclarations jamais utilisées)
#
# Les outils s'installent via Homebrew (hors de ce script) :
#   brew install swiftlint
#   brew install periphery
#
# Le projet Xcode est régénéré par XcodeGen au démarrage (project.yml = source
# de vérité ; le .xcodeproj est git-ignoré).
#
# Usage :
#   scripts/verify.sh
#
# Sortie : 0 si tout est propre, sinon le numéro de l'étape qui a échoué.
set -uo pipefail

# Se placer à la racine du dépôt (le script vit dans scripts/).
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SCHEME="Aether"
PROJECT="Aether.xcodeproj"
DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro"
DERIVED_DATA="build/dd"

# --- Vérifier la présence des outils ------------------------------------------
missing=0
for tool in swiftlint xcodebuild periphery xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "✗ outil manquant : $tool (cf. en-tête du script pour l'installation)" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 10

status=0

# --- 0. Régénérer le projet ---------------------------------------------------
echo "▸ XcodeGen — régénération du projet"
xcodegen generate >/dev/null

# --- 1. SwiftLint -------------------------------------------------------------
echo "▸ SwiftLint"
if swiftlint lint --strict --quiet; then
  echo "  ✓ SwiftLint : propre"
else
  echo "  ✗ SwiftLint : violations ci-dessus" >&2
  status=1
fi

# --- 2. xcodebuild analyze ----------------------------------------------------
echo "▸ xcodebuild analyze (peut prendre une minute)"
analyze_log="$(xcodebuild analyze \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" 2>&1)"

if ! printf '%s\n' "$analyze_log" | grep -q 'ANALYZE SUCCEEDED'; then
  echo "$analyze_log" | grep -E 'error:' | head -20 >&2
  echo "  ✗ analyze : la compilation a échoué" >&2
  status=2
else
  # On ne retient que les avertissements de notre code (pas les dépendances
  # SwiftPM ni les processus annexes de build).
  warnings="$(printf '%s\n' "$analyze_log" \
    | grep -E 'warning:' \
    | grep -vE 'SourcePackages|/checkouts/|appintentsmetadataprocessor|DerivedData' \
    || true)"
  if [ -n "$warnings" ]; then
    printf '%s\n' "$warnings" >&2
    echo "  ✗ analyze : avertissements ci-dessus" >&2
    status=2
  else
    echo "  ✓ analyze : aucun avertissement"
  fi
fi

# --- 3. Periphery -------------------------------------------------------------
echo "▸ Periphery (code mort)"
if periphery scan --strict --quiet --disable-update-check; then
  echo "  ✓ Periphery : aucun code mort"
else
  echo "  ✗ Periphery : code mort détecté ci-dessus" >&2
  status=3
fi

# --- Bilan --------------------------------------------------------------------
if [ "$status" -eq 0 ]; then
  echo "✅ Vérification complète : tout est propre."
else
  echo "❌ Vérification : échec (première étape en échec → code $status)." >&2
fi
exit "$status"
