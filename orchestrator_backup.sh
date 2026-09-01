#!/bin/bash
set -euo pipefail

# Initialisation du chronomètre
START_TIME=$SECONDS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/bot.env"
DUMP_SCRIPT="${SCRIPT_DIR}/dump_bases.sh"
CURL_TIMEOUT=10

# --- Chargement des variables d'environnement ---
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "Erreur : Fichier bot.env introuvable dans $SCRIPT_DIR" >&2
  exit 1
fi

# Échoue tôt et clairement si le .env est incomplet
: "${BOT_TOKEN:?BOT_TOKEN manquant dans ${ENV_FILE}}"
: "${CHAT_ID:?CHAT_ID manquant dans ${ENV_FILE}}"

# Utilise "kopia-backup" par défaut si KOPIA_CONTAINER n'est pas défini
KOPIA_CONTAINER="${KOPIA_CONTAINER:-kopia-backup}"

# Avertissement (non bloquant) si le .env est lisible par d'autres utilisateurs
PERMS=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo "")
if [ -n "$PERMS" ] && [ "$PERMS" != "600" ]; then
  echo "Avertissement : permissions de $ENV_FILE trop ouvertes ($PERMS). Recommandé : chmod 600 $ENV_FILE" >&2
fi

send_telegram() {
  local msg="$1"

  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --max-time "$CURL_TIMEOUT" --connect-timeout 5 \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode "text=${msg}" > /dev/null 2>&1 || true
}

on_exit() {
  local exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    send_telegram "❌ *Échec du backup NAS* (Code: $exit_code) : Une erreur est survenue lors du pipeline."
  fi
}

trap on_exit EXIT

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Démarrage de la chaîne de sauvegarde..."

# 1. Dumps des bases de données
echo "=== Étape 1 : Dumps des bases de données ==="

if [ ! -x "$DUMP_SCRIPT" ]; then
  echo "Erreur : $DUMP_SCRIPT introuvable ou non exécutable" >&2
  exit 1
fi

"$DUMP_SCRIPT"

# 2. Exécution de Kopia et capture de la sortie
echo "=== Étape 2 : Création des snapshots Kopia ==="

if docker ps --format '{{.Names}}' | grep -q "^${KOPIA_CONTAINER}$"; then
  KOPIA_OUTPUT=$(docker exec "$KOPIA_CONTAINER" kopia snapshot create --all 2>&1)
  echo "$KOPIA_OUTPUT"
else
  echo "Erreur : Conteneur Kopia introuvable ou arrêté" >&2
  exit 1
fi

# 2bis. Détection explicite d'erreurs dans la sortie Kopia.
# Un snapshot individuel peut échouer sans faire échouer la commande globale,
# donc on ne peut pas se fier uniquement au code de retour de "docker exec".
if echo "$KOPIA_OUTPUT" | grep -Eiq 'error|failed|panic'; then
  echo "Erreur détectée dans la sortie Kopia :" >&2
  echo "$KOPIA_OUTPUT" | grep -Ei 'error|failed|panic' >&2
  exit 1
fi

# 3. Traitement dossier par dossier (compatible tout awk/busybox)
# esc() échappe backtick et backslash pour ne pas casser le Markdown Telegram
# si un nom de dossier contient l'un de ces caractères
SNAPSHOT_DETAILS=$(echo "$KOPIA_OUTPUT" | awk '
  function esc(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/`/, "\\`", s)
    return s
  }

  /Snapshotting/ {
    sub(/.*:/, "", $2)
    dir = $2
  }

  /Created snapshot/ {
    if (dir != "") print "  • `" esc(dir) "` : ✅ *Nouveau snapshot*"
    dir = ""
  }

  /Not saving snapshot/ {
    if (dir != "") print "  • `" esc(dir) "` : ⏸️ _Inchangé_"
    dir = ""
  }
')

# 4. Calcul du temps écoulé
DURATION=$(( SECONDS - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECS=$(( DURATION % 60 ))

if [ "$MINUTES" -gt 0 ]; then
  TIME_STR="${MINUTES}m$(printf "%02d" "$SECS")s"
else
  TIME_STR="${SECS}s"
fi

# 5. Construction du message récapitulatif
if [ -z "$SNAPSHOT_DETAILS" ]; then
  MESSAGE="⚠️ *Sauvegarde NAS terminée, détail inattendu*
La commande Kopia s'est terminée sans erreur mais aucun dossier n'a été identifié dans la sortie. Vérifier manuellement le format (mise à jour de Kopia ?)."
else
  MESSAGE="💾 *Sauvegarde NAS réussie en ${TIME_STR}*

🗂️ *Détail par dossier :*
${SNAPSHOT_DETAILS}"
fi

# 6. Envoi de la notification détaillée
send_telegram "$MESSAGE"

log "Fin du pipeline en ${TIME_STR}."
