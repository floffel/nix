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
#   idm-users.sh user unlock <username>                       # clear expiry (valid indefinitely)
#   idm-users.sh user set-name <username> "<Display Name>" [--legal "<Legal Name>"]
#   idm-users.sh user set-mail <username> <addr> [<addr> ...] # replace the whole mail list
#   idm-users.sh user add-mail <username> <addr> [<addr> ...] # merge addresses into the list
#   idm-users.sh user del-mail <username> <addr> [<addr> ...] # remove addresses from the list
#   idm-users.sh user rename <old> <new>                      # rename the person (spn)
#
#   idm-users.sh group list
#   idm-users.sh group members <group>
#   idm-users.sh group add <group> <user> [<user> ...]
#   idm-users.sh group remove <group> <user> [<user> ...]
#   idm-users.sh group create <group>                         # ad-hoc group (service groups are provisioned)
#   idm-users.sh group delete <group>
#
#   idm-users.sh policy get <group>
#   idm-users.sh policy enable <group>                        # turn on account policy for the group
#   idm-users.sh policy min-credential <group> <any|mfa|passkey|attested_passkey>
#
#   idm-users.sh svc-token create <account> <display_name> <label> [expiry_iso] [--readwrite]
#   idm-users.sh svc-token status <account>
#   idm-users.sh svc-token revoke <account> <token_id>
#
#   idm-users.sh oauth2 list                              # list configured OIDC clients
#   idm-users.sh oauth2 get <client>                      # show a client's config
#   idm-users.sh oauth2 secret <client>                   # print the client's basic secret
#
# Environment:
#   KANIDM_ADMIN          acting admin DN (default: idm_admin)
#   RESET_TTL             default reset-token TTL in seconds (default: 3600)
#   KANIDM_ADMIN_PASSFILE password file for auto-login (default:
#                         /var/lib/secrets/kanidm/idm-admin-password)
#   KANIDM_OAUTH2_SECRETS dir holding per-client <client>/secret files
#                         (default: /var/lib/secrets/oauth2)
#   KANIDM_SKIP_LOGIN     set to 1 to skip the auto-login attempt
#
# The kanidm CLI reads its endpoint from /etc/kanidm/config (set up by the
# container configuration). On first use the script auto-logs in as $ADMIN
# using the password in $KANIDM_ADMIN_PASSFILE (the same file the NixOS
# provisioning hook uses), so you no longer need a manual
# `kanidm login -D idm_admin` beforehand. If the session is already valid the
# login step is skipped automatically.

set -euo pipefail

ADMIN="${KANIDM_ADMIN:-idm_admin}"
RESET_TTL_DEFAULT="${RESET_TTL:-3600}"
ADMIN_PASSFILE="${KANIDM_ADMIN_PASSFILE:-/var/lib/secrets/kanidm/idm-admin-password}"
  OAUTH2_SECRETS_DIR="${KANIDM_OAUTH2_SECRETS:-/var/lib/secrets/oauth2}"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Ensure there is a valid cached session for $ADMIN. If no session exists yet,
# log in non-interactively using the password file the NixOS provisioning hook
# also reads ($ADMIN_PASSFILE). A pre-existing session is left untouched, so
# this is safe to run before every command. Override with KANIDM_SKIP_LOGIN=1.
ensure_login() {
  [ "${KANIDM_SKIP_LOGIN:-0}" = "1" ] && return 0
  if kanidm login --name "$ADMIN" --check 2>/dev/null; then
    return 0
  fi
  [ -r "$ADMIN_PASSFILE" ] || die "no cached session for '$ADMIN' and password file '$ADMIN_PASSFILE' is missing/unreadable (set KANIDM_ADMIN_PASSFILE or run 'kanidm login -D $ADMIN' manually)"
  kanidm login --name "$ADMIN" --password "$(cat "$ADMIN_PASSFILE")" >/dev/null \
    || die "auto-login as '$ADMIN' failed (check $ADMIN_PASSFILE contents)"
}

# All kanidm invocations act as $ADMIN.
k() { ensure_login; kanidm "$@" --name "$ADMIN"; }

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
    unlock)
      # Clear the account expiry so it is valid indefinitely again.
      local username="${1:-}"; [ -n "$username" ] || die "usage: user unlock <username>"
      k person validity expire-at "$username" never
      echo "Account '$username' unlocked (valid indefinitely)."
      ;;
    set-name)
      local username="${1:-}"; local display="${2:-}"; shift 2 2>/dev/null || shift $# 2>/dev/null || true
      [ -n "$username" ] && [ -n "$display" ] || die 'usage: user set-name <username> "<Display Name>" [--legal "<Legal Name>"]'
      local legal=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --legal) legal="${2:-}"; shift 2 ;;
          *) die "unexpected argument '$1'"
        esac
      done
      if [ -n "$legal" ]; then
        k person update "$username" --displayname "$display" --legalname "$legal"
      else
        k person update "$username" --displayname "$display"
      fi
      echo "Updated display name for '$username'."
      ;;
    set-mail)
      # Replace the entire mail attribute list with the given addresses.
      local username="${1:-}"; shift || true
      [ -n "$username" ] && [ "$#" -ge 1 ] || die "usage: user set-mail <username> <addr> [<addr> ...]"
      local args=(); for a in "$@"; do args+=(--mail "$a"); done
      k person update "$username" "${args[@]}"
      echo "Replaced mail list for '$username' with: $*"
      ;;
    add-mail)
      # Merge new addresses into the existing mail list (kanidm --mail is
      # replace-semantics, so read current addresses first and re-apply the union).
      local username="${1:-}"; shift || true
      [ -n "$username" ] && [ "$#" -ge 1 ] || die "usage: user add-mail <username> <addr> [<addr> ...]"
      local current
      current="$(k person get "$username" 2>/dev/null | sed -n 's/^ *mail: *//p' | sort -u)" || current=""
      declare -A seen=()
      local args=() a
      while IFS= read -r a; do [ -n "$a" ] && seen["$a"]=1 && args+=(--mail "$a"); done <<< "$current"
      for a in "$@"; do
        [ -n "${seen[$a]:-}" ] && continue
        seen["$a"]=1; args+=(--mail "$a")
      done
      if [ "${#args[@]}" -eq 0 ]; then
        echo "No mail addresses to set for '$username'."
      else
        k person update "$username" "${args[@]}"
        echo "Added mail to '$username': $*"
      fi
      ;;
    del-mail)
      # Remove addresses from the existing mail list (re-apply the set difference).
      local username="${1:-}"; shift || true
      [ -n "$username" ] && [ "$#" -ge 1 ] || die "usage: user del-mail <username> <addr> [<addr> ...]"
      local current
      current="$(k person get "$username" 2>/dev/null | sed -n 's/^ *mail: *//p' | sort -u)" || current=""
      declare -A drop=(); for a in "$@"; do drop["$a"]=1; done
      local args=() a
      while IFS= read -r a; do
        [ -z "$a" ] && continue
        [ -n "${drop[$a]:-}" ] && continue
        args+=(--mail "$a")
      done <<< "$current"
      if [ "${#args[@]}" -eq 0 ]; then
        echo "Warning: removing all addresses; clearing mail for '$username'."
        k person update "$username" --mail ""
      else
        k person update "$username" "${args[@]}"
      fi
      echo "Removed mail from '$username': $*"
      ;;
    rename)
      local old="${1:-}"; local new="${2:-}"
      [ -n "$old" ] && [ -n "$new" ] || die "usage: user rename <old> <new>"
      k person update "$old" --newname "$new"
      echo "Renamed '$old' -> '$new'."
      ;;
    *) die "unknown user subcommand '$sub' (try: create get list delete reset-token lock unlock set-name set-mail add-mail del-mail rename)" ;;
  esac
}

cmd_group() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)        k group list ;;
    create)
      local group="${1:-}"; [ -n "$group" ] || die "usage: group create <group>"
      k group create "$group" idm_admins
      echo "Created ad-hoc group '$group'."
      ;;
    delete)
      local group="${1:-}"; [ -n "$group" ] || die "usage: group delete <group>"
      k group delete "$group"
      echo "Deleted group '$group'."
      ;;
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
    *) die "unknown group subcommand '$sub' (try: list create delete members add remove)" ;;
  esac
}

cmd_policy() {
  # Account-policy controls (credential floor, enable). The policy that applies
  # to all persons lives on the built-in idm_all_persons group; per-group
  # policies resolve to the strictest among a user's groups. See README §3.
  local sub="${1:-}"; shift || true
  case "$sub" in
    get)
      local group="${1:-}"; [ -n "$group" ] || die "usage: policy get <group>"
      k group account-policy credential-type-minimum "$group"
      ;;
    enable)
      local group="${1:-}"; [ -n "$group" ] || die "usage: policy enable <group>"
      k group account-policy enable "$group"
      echo "Account policy enabled for '$group'."
      ;;
    min-credential)
      local group="${1:-}"; local level="${2:-}"
      [ -n "$group" ] && [ -n "$level" ] || die "usage: policy min-credential <group> <any|mfa|passkey|attested_passkey>"
      case "$level" in
        any|mfa|passkey|attested_passkey) ;;
        *) die "level must be one of: any mfa passkey attested_passkey" ;;
      esac
      k group account-policy credential-type-minimum "$group" "$level"
      echo "Set '$group' credential floor to '$level'."
      ;;
    *) die "unknown policy subcommand '$sub' (try: get enable min-credential)" ;;
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

cmd_oauth2() {
  # Read-only views of the provisioned OAuth2/OIDC clients. Clients and their
  # scope/claim maps are declared in kanidm.nix and reconciled by the NixOS
  # provisioning hook, so this area intentionally has no create/update/delete.
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)
      k system oauth2 list
      ;;
    get)
      local client="${1:-}"; [ -n "$client" ] || die "usage: oauth2 get <client>"
      k system oauth2 get "$client"
      ;;
    secret)
      # Print a non-public client's basic secret straight from the shared
      # secrets file the provisioning hook also reads. This is the same file
      # bind-mounted (read-only) into the consuming container, so no manual
      # copy/sync to the consumer is needed anymore — the file IS the shared
      # secret. Useful for inspecting the value or seeding a fresh NAS share.
      local client="${1:-}"; [ -n "$client" ] || die "usage: oauth2 secret <client>"
      local f="$OAUTH2_SECRETS_DIR/$client/secret"
      [ -r "$f" ] || die "basic secret file '$f' not found/unreadable (client '$client' may be public/PKCE, or set KANIDM_OAUTH2_SECRETS)"
      cat "$f"
      ;;
    *) die "unknown oauth2 subcommand '$sub' (try: list get secret)" ;;
  esac
}

main() {
  [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage 0
  [ "$#" -ge 1 ] || usage 1
  local area="$1"; shift
  case "$area" in
    user)       cmd_user "$@" ;;
    group)      cmd_group "$@" ;;
    policy)     cmd_policy "$@" ;;
    oauth2)     cmd_oauth2 "$@" ;;
    svc-token)  cmd_svc_token "$@" ;;
    -h|--help)  usage 0 ;;
    *)          usage 1 ;;
  esac
}

main "$@"
