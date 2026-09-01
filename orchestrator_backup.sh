#!/bin/bash
set -euo pipefail

# Initialize timer
START_TIME=$SECONDS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/bot.env"
DUMP_SCRIPT="${SCRIPT_DIR}/dump_bases.sh"
CURL_TIMEOUT=10

# --- Load environment variables ---
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "Error: bot.env file not found in $SCRIPT_DIR" >&2
  exit 1
fi

# Fail early with a clear message if the environment file is incomplete
: "${BOT_TOKEN:?BOT_TOKEN is missing from ${ENV_FILE}}"
: "${CHAT_ID:?CHAT_ID is missing from ${ENV_FILE}}"

# Use "kopia-backup" as the default container name if KOPIA_CONTAINER is not defined
KOPIA_CONTAINER="${KOPIA_CONTAINER:-kopia-backup}"

# Non-blocking warning if the environment file can be read by other users
PERMS=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo "")
if [ -n "$PERMS" ] && [ "$PERMS" != "600" ]; then
  echo "Warning: permissions on $ENV_FILE are too permissive ($PERMS). Recommended: chmod 600 $ENV_FILE" >&2
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
    send_telegram "❌ *NAS backup failed* (Exit code: $exit_code): An error occurred during the backup pipeline."
  fi
}

trap on_exit EXIT

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Starting backup pipeline..."

# 1. Create database dumps
echo "=== Step 1: Creating database backups ==="

if [ ! -x "$DUMP_SCRIPT" ]; then
  echo "Error: $DUMP_SCRIPT not found or not executable" >&2
  exit 1
fi

"$DUMP_SCRIPT"

# 2. Run Kopia and capture its output
echo "=== Step 2: Creating Kopia snapshots ==="

if docker ps --format '{{.Names}}' | grep -q "^${KOPIA_CONTAINER}$"; then
  KOPIA_OUTPUT=$(docker exec "$KOPIA_CONTAINER" kopia snapshot create --all 2>&1)
  echo "$KOPIA_OUTPUT"
else
  echo "Error: Kopia container not found or not running" >&2
  exit 1
fi

# 2bis. Explicitly detect errors in Kopia output.
# An individual snapshot may fail without causing the overall command to fail,
# so the exit code from "docker exec" alone is not always sufficient.
if echo "$KOPIA_OUTPUT" | grep -Eiq 'error|failed|panic'; then
  echo "Error detected in Kopia output:" >&2
  echo "$KOPIA_OUTPUT" | grep -Ei 'error|failed|panic' >&2
  exit 1
fi

# 3. Process each snapshot individually (compatible with awk/BusyBox)
# esc() escapes backticks and backslashes to prevent Telegram Markdown
# formatting issues if a directory name contains either character.
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
    if (dir != "") print "  • `" esc(dir) "` : ✅ *New snapshot*"
    dir = ""
  }

  /Not saving snapshot/ {
    if (dir != "") print "  • `" esc(dir) "` : ⏸️ _Unchanged_"
    dir = ""
  }
')

# 4. Calculate elapsed time
DURATION=$(( SECONDS - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECS=$(( DURATION % 60 ))

if [ "$MINUTES" -gt 0 ]; then
  TIME_STR="${MINUTES}m$(printf "%02d" "$SECS")s"
else
  TIME_STR="${SECS}s"
fi

# 5. Build summary message
if [ -z "$SNAPSHOT_DETAILS" ]; then
  MESSAGE="⚠️ *NAS backup completed with unexpected details*
Kopia completed without reporting an error, but no snapshot directories were identified in its output. Please check the output format manually (possibly after a Kopia update)."
else
  MESSAGE="💾 *NAS backup completed successfully in ${TIME_STR}*

🗂️ *Snapshot details:*
${SNAPSHOT_DETAILS}"
fi

# 6. Send detailed notification
send_telegram "$MESSAGE"

log "Backup pipeline completed in ${TIME_STR}."
