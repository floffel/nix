#!/usr/bin/env bash
# idm-users.sh — CRUD helper for Kanidm person/group/service-account lifecycle.
#
# Run this on the nixidm container as root (or any user with kanidm CLI access).
# It wraps the kanidm CLI to give a simple command interface for onboarding and
# day-to-day user administration. Person creation never sets a password inline;
# instead it issues a single-use credential-reset token the user redeems in the
# web UI to set their own password (and optionally enroll passkeys/MFA).
#
# Usage:
#   idm-users.sh user create <username> "<Display Name>" [primary_mail] [alias_mail ...]
#   idm-users.sh user get <username>
#   idm-users.sh user list
#   idm-users.sh user delete <username>
#   idm-users.sh user reset-token <username> [ttl_seconds]   # default 3600, max 86400
#   idm-users.sh user lock <username>                         # expire account now
#
#   idm-users.sh group list
#   idm-users.sh group members <group>
#   idm-users.sh group add <group> <user> [<user> ...]
#   idm-users.sh group remove <group> <user> [<user> ...]
#
#   idm-users.sh svc-token create <account> <display_name> <label> [expiry_iso] [--readwrite]
#   idm-users.sh svc-token status <account>
#   idm-users.sh svc-token revoke <account> <token_id>
#
# Environment:
#   KANIDM_ADMIN  acting admin DN (default: idm_admin)
#   RESET_TTL     default reset-token TTL in seconds (default: 3600)
#
# The kanidm CLI reads its endpoint from /etc/kanidm/config (set up by the
# container configuration). Auth is via the admin's cached session; run
# `kanidm login -D idm_admin` once before using this script.

set -euo pipefail

ADMIN="${KANIDM_ADMIN:-idm_admin}"
RESET_TTL_DEFAULT="${RESET_TTL:-3600}"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# All kanidm invocations act as $ADMIN.
k() { kanidm "$@" --name "$ADMIN"; }

cmd_user() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    create)
      local username="${1:-}"; local display="${2:-}"; shift 2 2>/dev/null || shift $# 2>/dev/null || true
      [ -n "$username" ] && [ -n "$display" ] || die "usage: user create <username> \"<Display Name>\" [primary_mail] [alias_mail ...]"
      k person create "$username" "$display"
      if [ "$#" -gt 0 ]; then
        k person update "$username" --mail "$@"
      fi
      echo
      echo "User '$username' created. Issue a reset token so they can set their own password:"
      echo "  $0 user reset-token $username"
      ;;
    get)
      local username="${1:-}"; [ -n "$username" ] || die "usage: user get <username>"
      k person get "$username"
      ;;
    list)
      k person list
      ;;
    delete)
      local username="${1:-}"; [ -n "$username" ] || die "usage: user delete <username>"
      k person delete "$username"
      echo "Deleted user '$username'."
      ;;
    reset-token)
      local username="${1:-}"; local ttl="${2:-$RESET_TTL_DEFAULT}"
      [ -n "$username" ] || die "usage: user reset-token <username> [ttl_seconds]"
      [ "$ttl" -le 86400 ] 2>/dev/null || die "ttl must be <= 86400 (24h)"
      k person credential create-reset-token "$username" "$ttl"
      ;;
    lock)
      local username="${1:-}"; [ -n "$username" ] || die "usage: user lock <username>"
      k person validity expire-at "$username" now
      echo "Account '$username' expired (locked)."
      ;;
    *) die "unknown user subcommand '$sub' (try: create get list delete reset-token lock)" ;;
  esac
}

cmd_group() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)        k group list ;;
    members)
      local group="${1:-}"; [ -n "$group" ] || die "usage: group members <group>"
      k group list-members "$group"
      ;;
    add)
      local group="${1:-}"; shift || true
      [ -n "$group" ] && [ "$#" -ge 1 ] || die "usage: group add <group> <user> [<user> ...]"
      k group add-members "$group" "$@"
      echo "Added to '$group': $*"
      ;;
    remove)
      local group="${1:-}"; shift || true
      [ -n "$group" ] && [ "$#" -ge 1 ] || die "usage: group remove <group> <user> [<user> ...]"
      k group remove-members "$group" "$@"
      echo "Removed from '$group': $*"
      ;;
    *) die "unknown group subcommand '$sub' (try: list members add remove)" ;;
  esac
}

cmd_svc_token() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    create)
      local account="${1:-}"; local display="${2:-}"; local label="${3:-}"; local expiry="${4:-}"
      [ -n "$account" ] && [ -n "$display" ] && [ -n "$label" ] || \
        die "usage: svc-token create <account> <display_name> <label> [expiry_iso] [--readwrite]"
      # Pass through any trailing --readwrite flag.
      local rw=""
      for a in "$@"; do [ "$a" = "--readwrite" ] && rw="--readwrite"; done
      if [ -n "$expiry" ] && [ "$expiry" != "--readwrite" ]; then
        k service-account api-token generate "$rw" "$account" "$label" "$expiry"
      else
        k service-account api-token generate "$rw" "$account" "$label"
      fi
      ;;
    status)
      local account="${1:-}"; [ -n "$account" ] || die "usage: svc-token status <account>"
      k service-account api-token status "$account"
      ;;
    revoke)
      local account="${1:-}"; local token_id="${2:-}"
      [ -n "$account" ] && [ -n "$token_id" ] || die "usage: svc-token revoke <account> <token_id>"
      k service-account api-token destroy "$account" "$token_id"
      echo "Revoked token $token_id for '$account'."
      ;;
    *) die "unknown svc-token subcommand '$sub' (try: create status revoke)" ;;
  esac
}

main() {
  [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage 0
  [ "$#" -ge 1 ] || usage 1
  local area="$1"; shift
  case "$area" in
    user)       cmd_user "$@" ;;
    group)      cmd_group "$@" ;;
    svc-token)  cmd_svc_token "$@" ;;
    -h|--help)  usage 0 ;;
    *)          usage 1 ;;
  esac
}

main "$@"
