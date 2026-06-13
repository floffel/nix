#!/usr/bin/env bash
# Helper script to automatically generate secure random passwords for nixpostgres roles
# and apply them using PostgreSQL peer authentication.
# Run this script on the nixpostgres container as root.

set -e

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script as root (or via sudo)."
  exit 1
fi

# Roles to configure
ROLES=("roundcube" "nextcloud" "forgejo" "matrix" "vaultwarden" "wikijs")

declare -A PASSWORDS

echo "==============================================="
echo " Generating Random Passwords & Updating Roles  "
echo "==============================================="

for role in "${ROLES[@]}"; do
  # Generate a secure 24-character alphanumeric password
  password=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)
  PASSWORDS[$role]=$password

  # Apply password to PostgreSQL
  echo "Updating role: $role..."
  sudo -u postgres psql -c "ALTER ROLE $role WITH PASSWORD '$password';" >/dev/null
done

echo ""
echo "==============================================="
echo "      PostgreSQL Role Credentials Configured   "
echo "==============================================="
echo "Copy these credentials to your service secrets:"
echo ""

for role in "${ROLES[@]}"; do
  printf "Role: %-12s | Password: %s\n" "$role" "${PASSWORDS[$role]}"
done

echo "==============================================="
echo "Warning: Store these credentials securely. They will not be displayed again."
echo "==============================================="
