#!/usr/bin/env bash
# =====================================================================
# Construction des trois APK, avec leur configuration
# =====================================================================
# Les clés n'entrent PAS dans le code : elles arrivent par --dart-define au
# moment de la compilation. Compiler sans elles produit un APK qui s'installe,
# se lance, et n'affiche qu'un écran gris — « Configuration manquante ». Rien
# n'échoue à la compilation, et c'est exactement le piège : trois APK valides,
# trois apps mortes.
#
# D'où ce script. La commande complète ne doit pas vivre dans la mémoire de
# celui qui la tape.
#
#   ./build_apks.sh            → les trois, en release
#   ./build_apks.sh driver     → un seul
#   MODE=debug ./build_apks.sh → en debug
set -euo pipefail

cd "$(dirname "$0")"

# Les valeurs viennent du .env du backend : une seule source, pour que l'app
# et le serveur ne puissent pas diverger en silence.
ENV_FILE="../backend/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Introuvable : $ENV_FILE" >&2
  exit 1
fi

lire() {
  # Sans `head -1`, une clé définie deux fois donnerait deux lignes collées.
  grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"'\r'
}

SUPABASE_URL="$(lire SUPABASE_URL)"
SUPABASE_ANON_KEY="$(lire SUPABASE_ANON_KEY)"
API_BASE_URL="$(lire PUBLIC_BASE_URL)"

for nom in SUPABASE_URL SUPABASE_ANON_KEY API_BASE_URL; do
  if [[ -z "${!nom}" ]]; then
    echo "$nom est vide dans $ENV_FILE — l'app afficherait « Configuration manquante »." >&2
    exit 1
  fi
done

MODE="${MODE:-release}"
FLAVORS=("${@:-client driver merchant}")
# shellcheck disable=SC2206
FLAVORS=(${FLAVORS[*]})

echo "Backend  : $API_BASE_URL"
echo "Supabase : $SUPABASE_URL"
echo

for f in "${FLAVORS[@]}"; do
  echo "=== $f ($MODE) ==="
  flutter build apk "--$MODE" --flavor "$f" -t "lib/main_$f.dart" \
    --dart-define=SUPABASE_URL="$SUPABASE_URL" \
    --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
    --dart-define=API_BASE_URL="$API_BASE_URL"
done

echo
ls -l build/app/outputs/flutter-apk/*.apk 2>/dev/null \
  | awk '{printf "  %.1f Mo  %s\n", $5/1048576, $9}'
