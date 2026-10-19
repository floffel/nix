#!/usr/bin/env bash
# Manage Kanidm-driven shared mailboxes.
#
# A group named mail_shared_<owner> grants its members access to the owner's
# mailbox (<owner>@minnecker.com). The nixmail mail-shared-mailboxes service
# reads these groups from LDAP and creates the Maildir symlinks + ACLs.
set -euo pipefail

ADMIN=idm_admin
PW_FILE=/var/lib/secrets/kanidm/idm-admin-password
PREFIX=mail_shared_

login() {
  kanidm login --name "$ADMIN" --password "$(cat "$PW_FILE")" >/dev/null 2>&1 || true
}

k() {
  kanidm "$@" --name "$ADMIN"
}

group_name() {
  printf '%s%s' "$PREFIX" "$1"
}

sync() {
  if ssh -o BatchMode=yes -o ConnectTimeout=5 nixmail 'systemctl start mail-shared-mailboxes.service' >/dev/null 2>&1; then
    echo "Synced shared mailboxes."
  else
    echo "Group updated. Run 'systemctl start mail-shared-mailboxes' on nixmail to sync." >&2
  fi
}

usage() {
  cat <<EOF
Usage:
  $0 create <owner> [member ...]
  $0 delete <owner>
  $0 add-member <owner> <member> [...]
  $0 del-member <owner> <member> [...]
  $0 list

Groups are named ${PREFIX}<owner>; members are Kanidm usernames
(not mail addresses). The owner must be a mail user.
EOF
}

cmd=${1:-}
shift || true

case "$cmd" in
  create)
    owner=${1:-}
    shift || true
    [ -n "$owner" ] || { usage; exit 2; }
    login
    k group create "$(group_name "$owner")"
    [ "$#" -gt 0 ] && k group add-members "$(group_name "$owner")" "$@"
    sync
    ;;
  delete)
    owner=${1:-}
    [ -n "$owner" ] || { usage; exit 2; }
    login
    k group delete "$(group_name "$owner")"
    sync
    ;;
  add-member)
    owner=${1:-}
    shift || true
    [ -n "$owner" ] && [ "$#" -gt 0 ] || { usage; exit 2; }
    login
    k group add-members "$(group_name "$owner")" "$@"
    sync
    ;;
  del-member)
    owner=${1:-}
    shift || true
    [ -n "$owner" ] && [ "$#" -gt 0 ] || { usage; exit 2; }
    login
    k group remove-members "$(group_name "$owner")" "$@"
    sync
    ;;
  list)
    login
    k group list | grep "^${PREFIX}" || true
    ;;
  *)
    usage
    exit 2
    ;;
esac
