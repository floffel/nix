#!/usr/bin/env bash
# Helper script to set up the Forgejo database secret.
# Run this script on the nixforgejo container as root.
# Usage: ./setup-forgejo-secrets.sh <DB_PASSWORD>
#
# The OAuth2/OIDC client secret is no longer written here. It is read from the
# shared OAuth2 secrets mount at /var/lib/secrets/oauth2/forgejo/secret, which
# is bind-mounted (read-only) from the NAS and provisioned on nixidm. See the
# nixforgejo and root READMEs for the mount setup.

set -e

DB_PASSWORD="$1"

if [ -z "$DB_PASSWORD" ]; then
  echo "Error: DB_PASSWORD is required."
  echo "Usage: $0 <DB_PASSWORD>"
  exit 1
fi

DEST_DIR="/var/lib/secrets/forgejo"
mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

# Write the database password secret
echo -n "$DB_PASSWORD" > "$DEST_DIR/db-password"
chmod 600 "$DEST_DIR/db-password"

# Resolve forgejo user/group dynamically (fallback to root if not created yet)
FORGEJO_USER="root"
FORGEJO_GROUP="root"
if id forgejo >/dev/null 2>&1; then
  FORGEJO_USER=$(id -u forgejo)
  FORGEJO_GROUP=$(id -g forgejo)
fi

chown -R "$FORGEJO_USER:$FORGEJO_GROUP" "$DEST_DIR"

echo "Success: Forgejo db-password written to $DEST_DIR"
if [ "$FORGEJO_USER" = "root" ]; then
  echo "Warning: User 'forgejo' was not found on this system."
  echo "Please run this script again after building/switching the NixOS configuration to apply the correct ownership."
else
  echo "Ownership set to forgejo:forgejo (UID $FORGEJO_USER)."
fi
