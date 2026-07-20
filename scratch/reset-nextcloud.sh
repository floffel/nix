#!/usr/bin/env bash
# Clean-slate reset of Nextcloud — nukes config, data dir, and database
# so the next nixos-rebuild switch performs a fresh install.
#
# Run this on nixnginx as root.
#
# DB reset runs on nixpostgres via SSH. If SSH isn't available, run the
# psql commands manually on nixpostgres.
#
# Options:
#   --skip-db   Skip the database reset step (e.g. after running it manually)
set -euo pipefail

SKIP_DB=false
for arg in "$@"; do
  case "$arg" in
    --skip-db) SKIP_DB=true ;;
    *) die "Unknown option: $arg" ;;
  esac
done

echo "=== Nextcloud Clean-Slate Reset ==="
echo ""

# -- helpers ---------------------------------------------------------
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  -> $*"; }

# -- 1. Stop systemd services ----------------------------------------
info "Stopping Nextcloud systemd services..."
systemctl stop nextcloud-setup-oidc.service 2>/dev/null || true
systemctl stop nextcloud-cron.service      2>/dev/null || true
systemctl stop phpfpm-nextcloud.service    2>/dev/null || true

# -- 2. Tear down config ---------------------------------------------
CONFIG_FILE=/var/lib/nextcloud/config/config.php
DATA_DIR=/var/lib/nextcloud-data

if [ -f "$CONFIG_FILE" ]; then
  info "Deleting $CONFIG_FILE"
  rm -f "$CONFIG_FILE"
else
  info "No config.php found — already clean"
fi

if [ -f "$DATA_DIR/config/config.php" ]; then
  info "Deleting $DATA_DIR/config/config.php"
  rm -f "$DATA_DIR/config/config.php"
fi

# -- 3. Wipe data directory ------------------------------------------
# Keep the config/ subdirectory (expected by systemd-tmpfiles with
# nextcloud:nextcloud ownership). Only wipe user data.
if [ -d "$DATA_DIR/data" ]; then
  info "Wiping $DATA_DIR/data/* ..."
  find "$DATA_DIR/data" -mindepth 1 -delete
else
  info "Data dir $DATA_DIR/data does not exist, creating..."
  install -d -o nextcloud -g nextcloud "$DATA_DIR/data"
fi

# Ensure config/ exists with correct ownership (tmpfiles will fix it
# on next rebuild, but pre-seeding avoids "not owned by nextcloud").
if [ ! -d "$DATA_DIR/config" ]; then
  install -d -o nextcloud -g nextcloud "$DATA_DIR/config"
else
  chown nextcloud:nextcloud "$DATA_DIR/config"
fi

# -- 4. Reset database on nixpostgres -------------------------------
DB_NAME=nextcloud
DB_USER=nextcloud
DB_HOST=nixpostgres

if $SKIP_DB; then
  info "Skipping database reset (--skip-db)"
else
  info "Resetting PostgreSQL database '$DB_NAME' on $DB_HOST..."

# Try SSH first, fall back to remote psql, last resort manual.
if ssh -o ConnectTimeout=3 "$DB_HOST" true 2>/dev/null; then
  info "  Using SSH to nixpostgres"
  ssh "$DB_HOST" <<'REMOTE'
    set -euo pipefail
    echo "    Dropping database…"
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS nextcloud;"
    echo "    Creating database…"
    sudo -u postgres psql -c "CREATE DATABASE nextcloud OWNER nextcloud;"
    echo "    Done."
REMOTE
else
  if command -v psql >/dev/null 2>&1; then
    PASSFILE=/var/lib/secrets/postgres/nextcloud/db-password
    if [ -f "$PASSFILE" ]; then
      PGPASS="$(cat "$PASSFILE")"
      info "  Using remote psql from nixnginx"
      PGPASSWORD="$PGPASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null || true
      PGPASSWORD="$PGPASS" psql -h "$DB_HOST" -U "$DB_USER" -d postgres \
        -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
      info "  Created database via remote psql"
    else
      die "Password file $PASSFILE not found"
    fi
  else
    echo ""
    echo "=== MANUAL STEP REQUIRED ==="
    echo "  Neither SSH nor psql available. Run this on nixpostgres as root:"
    echo ""
    echo "    sudo -u postgres psql -c 'DROP DATABASE IF EXISTS $DB_NAME;'"
    echo "    sudo -u postgres psql -c 'CREATE DATABASE $DB_NAME OWNER $DB_USER;'"
    echo ""
    echo "  Then run this script again with --skip-db to finish the reset."
    echo "=============================="
    exit 1
  fi
fi
fi  # end of SKIP_DB / else block

# -- 5. Done ---------------------------------------------------------
echo ""
echo "=== Reset complete ==="
echo ""
echo "Next step: rebuild the NixOS configuration on nixnginx:"
echo ""
echo "  nixos-rebuild switch"
echo ""
echo "This will run nextcloud-setup.service (fresh install) followed by"
echo "nextcloud-setup-oidc.service (Kanidm OIDC registration)."