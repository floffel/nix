#!/usr/bin/env bash
# Helper script to set up Forgejo Actions Runner secrets
# Run this script on the nixforgejo-runner container as root.
# Usage: ./setup-forgejo-runner-secrets.sh <RUNNER_REGISTRATION_TOKEN>

set -e

RUNNER_TOKEN="$1"

if [ -z "$RUNNER_TOKEN" ]; then
  echo "Error: RUNNER_REGISTRATION_TOKEN is required."
  echo "Usage: $0 <RUNNER_REGISTRATION_TOKEN>"
  exit 1
fi

DEST_DIR="/var/lib/secrets/forgejo"
mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

# Write token
echo "TOKEN=$RUNNER_TOKEN" > "$DEST_DIR/runner-token"
chmod 600 "$DEST_DIR/runner-token"

# Resolve gitea-runner user/group dynamically (fallback to root if not created yet)
RUNNER_USER="root"
RUNNER_GROUP="root"
if id gitea-runner >/dev/null 2>&1; then
  RUNNER_USER=$(id -u gitea-runner)
  RUNNER_GROUP=$(id -g gitea-runner)
fi

chown -R "$RUNNER_USER:$RUNNER_GROUP" "$DEST_DIR"

echo "Success: Forgejo Actions Runner secrets written to $DEST_DIR"
if [ "$RUNNER_USER" = "root" ]; then
  echo "Warning: User 'gitea-runner' was not found on this system."
  echo "Please run this script again after building/switching the NixOS configuration to apply the correct ownership."
else
  echo "Ownership set to gitea-runner:gitea-runner (UID $RUNNER_USER)."
fi
