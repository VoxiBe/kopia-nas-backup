#!/bin/bash
set -euo pipefail

EXPORT_DIR="/volume1/docker/backups_db"
mkdir -p "$EXPORT_DIR/vaultwarden" "$EXPORT_DIR/wealthfolio" "$EXPORT_DIR/yamtrack" "$EXPORT_DIR/immich" "$EXPORT_DIR/jellyfin"

echo "=== 1/5 : Export Immich (PostgreSQL) ==="
if docker ps --format '{{.Names}}' | grep -q "^immich_postgres$"; then
  docker exec immich_postgres pg_dumpall -c -U postgres | gzip > "$EXPORT_DIR/immich/immich_db.sql.gz"
else
  echo "Erreur : Conteneur immich_postgres arrêté ou introuvable !" >&2
  exit 1
fi

echo "=== 2/5 : Export Vaultwarden (SQLite) ==="
sqlite3 /volume1/docker/vaultwarden/data/db.sqlite3 ".timeout 10000" ".backup '$EXPORT_DIR/vaultwarden/vaultwarden.db'"

echo "=== 3/5 : Export Wealthfolio (SQLite) ==="
sqlite3 /volume1/docker/wealthfolio/data/wealthfolio.db ".timeout 10000" ".backup '$EXPORT_DIR/wealthfolio/wealthfolio.db'"

echo "=== 4/5 : Export Yamtrack (SQLite & Redis) ==="
sqlite3 /volume1/docker/yamtrack/db/db.sqlite3 ".timeout 10000" ".backup '$EXPORT_DIR/yamtrack/yamtrack.db'"

if docker ps --format '{{.Names}}' | grep -q "^yamtrack-redis$"; then
  docker exec yamtrack-redis redis-cli SAVE > /dev/null 2>&1
  cp /volume1/docker/yamtrack/redis_data/dump.rdb "$EXPORT_DIR/yamtrack/dump.rdb"
else
  echo "Erreur : Conteneur yamtrack-redis arrêté ou introuvable !" >&2
  exit 1
fi

echo "=== 5/5 : Export Jellyfin (SQLite) ==="
if [ -f "/volume1/docker/jellyfin/config/data/jellyfin.db" ]; then
  sqlite3 /volume1/docker/jellyfin/config/data/jellyfin.db ".timeout 10000" ".backup '$EXPORT_DIR/jellyfin/jellyfin.db'"
else
  echo "Erreur : Base Jellyfin introuvable dans /volume1/docker/jellyfin/config/data !" >&2
  exit 1
fi

echo "=== Sauvegardes terminées avec succès ==="
