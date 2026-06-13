#!/usr/bin/env bash
# Helper script to set up Forgejo database and OIDC secrets
# Run this script on the nixforgejo container as root.
# Usage: ./setup-forgejo-secrets.sh <DB_PASSWORD> <OAUTH_SECRET>

set -e

DB_PASSWORD="$1"
OAUTH_SECRET="$2"

if [ -z "$DB_PASSWORD" ] || [ -z "$OAUTH_SECRET" ]; then
  echo "Error: Both DB_PASSWORD and OAUTH_SECRET are required."
  echo "Usage: $0 <DB_PASSWORD> <OAUTH_SECRET>"
  exit 1
fi

DEST_DIR="/var/lib/secrets/forgejo"
mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

# Write secrets
echo -n "$DB_PASSWORD" > "$DEST_DIR/db-password"
echo -n "$OAUTH_SECRET" > "$DEST_DIR/oauth-secret"

chmod 600 "$DEST_DIR/db-password" "$DEST_DIR/oauth-secret"

# Resolve forgejo user/group dynamically (fallback to root if not created yet)
FORGEJO_USER="root"
FORGEJO_GROUP="root"
if id forgejo >/dev/null 2>&1; then
  FORGEJO_USER=$(id -u forgejo)
  FORGEJO_GROUP=$(id -g forgejo)
fi

chown -R "$FORGEJO_USER:$FORGEJO_GROUP" "$DEST_DIR"

echo "Success: Forgejo secrets written to $DEST_DIR"
if [ "$FORGEJO_USER" = "root" ]; then
  echo "Warning: User 'forgejo' was not found on this system."
  echo "Please run this script again after building/switching the NixOS configuration to apply the correct ownership."
else
  echo "Ownership set to forgejo:forgejo (UID $FORGEJO_USER)."
fi
