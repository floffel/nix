#!/bin/bash
#
# Nightly backup of the Proxmox host's own state that no vzdump job covers.
#
# Why this exists: shared secrets used by more than one container live on the
# host's local disk under /var/lib/secrets (see README, "Secrets on the Proxmox
# host's own disk"). vzdump backs up the *containers*, so a host disk loss
# would take those files with it -- and without them nixmatrix/nixpostgresql/
# nixidm/nixnginx cannot start (DB passwords, the MAS OIDC client secret, the
# coturn shared secret). The LXC configs are included for the same reason:
# they carry the bind-mount entries that wire the secrets into each container,
# and /root/backups holds the pre-change LXC configs plus the archived copies
# of NAS shares that were retired when the secrets moved to the host disk.
#
# Where the off-host copy lives: the restic repository in the Garage S3 bucket
# "pxbackup", written by px-s3-backup.sh every night at 23:30 (it snapshots the
# same files under the tag "host").  This script does not upload anything
# itself -- it would need the repository password and would race the nightly
# run for the repository lock -- so instead it *verifies* the off-host copy and
# fails loudly when that copy has gone stale.  A local archive alone is not a
# backup: it dies with the host disk.
#
# Usage:  backup-host-secrets.sh [--keep N]
# Exit:   0 when the local archive is good and the S3 copy is fresh,
#         non-zero otherwise.

set -uo pipefail

LOCAL_DIR=/var/backups/host-secrets
# Repository coordinates of the off-host copy (Garage bucket "pxbackup").
RESTIC_ENV=/etc/px-backup.env
# px-s3-backup.sh runs at 23:30, this check at 02:30; anything older than this
# means the nightly S3 run did not happen (or failed) -- more than one night.
MAX_AGE_HOURS=26
KEEP=14

# What goes into the archive. Paths are added only if they exist, so a host
# without every service still produces a useful archive.
PATHS=()
for p in /var/lib/secrets /etc/pve/lxc /etc/pve/storage.cfg /root/backups; do
  [ -e "$p" ] && PATHS+=("$p")
done

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ${#PATHS[@]} -eq 0 ]; then
  echo "ERROR: nothing to back up" >&2
  exit 1
fi

umask 077
STAMP=$(date -u +%F)
ARCHIVE="host-secrets-${STAMP}.tar.zst"
LOCAL_FILE="${LOCAL_DIR}/${ARCHIVE}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail=0

mkdir -p "$LOCAL_DIR" || exit 1

# "-C /" keeps members relative to / (var/lib/secrets/...), so restoring is
# "tar -C / -xf archive" with no surprise directory layout.
#
# -h is required, not cosmetic: /etc/pve is pmxcfs (FUSE) and /etc/pve/lxc is a
# symlink to nodes/<node>/lxc. Without -h tar stores the symlink itself and the
# archive silently contains zero .conf files.
# Write to a temp name and rename: zstd refuses to overwrite an existing file,
# so a same-day re-run (manual retry, or Persistent=true catching up a missed
# night) would otherwise fail, and a crash mid-write must not leave a truncated
# archive under the final name.
if ! tar -hcf - -C / "${PATHS[@]}" 2>/dev/null | zstd -q -T0 -19 -o "${LOCAL_FILE}.tmp"; then
  echo "ERROR: failed to write ${LOCAL_FILE}.tmp" >&2
  rm -f "${LOCAL_FILE}.tmp"
  exit 1
fi

if ! mv "${LOCAL_FILE}.tmp" "$LOCAL_FILE"; then
  echo "ERROR: could not move the archive into place" >&2
  rm -f "${LOCAL_FILE}.tmp"
  exit 1
fi

# An archive nobody has opened is not a backup: verify it reads back.
if ! zstd -t "$LOCAL_FILE" 2>/dev/null || ! zstd -dc "$LOCAL_FILE" 2>/dev/null | tar -tf - >/dev/null; then
  echo "ERROR: $LOCAL_FILE failed verification" >&2
  exit 1
fi

MEMBERS=$(zstd -dc "$LOCAL_FILE" 2>/dev/null | tar -tf -)
FILES=$(printf '%s\n' "$MEMBERS" | grep -vc '/$' || true)
log "wrote $LOCAL_FILE ($(du -h "$LOCAL_FILE" | cut -f1), $FILES files)"

# Invariant: every requested path must actually be represented. This is what
# catches a whole subtree going missing (the /etc/pve/lxc symlink case above).
for p in "${PATHS[@]}"; do
  # A path may be a directory (members follow it with "/") or a single file
  # (the member is the path itself), so accept both.
  if ! printf '%s\n' "$MEMBERS" | grep -qE "^${p#/}(/|\$)"; then
    echo "ERROR: archive has no member for $p" >&2
    fail=1
  fi
done
[ "$fail" -ne 0 ] && exit 1

prune() {
  dir="$1"
  n=$(find "$dir" -maxdepth 1 -name 'host-secrets-*.tar.zst' 2>/dev/null | wc -l)
  [ "$n" -le "$KEEP" ] && return 0
  deleted=$(find "$dir" -maxdepth 1 -name 'host-secrets-*.tar.zst' -printf '%f\n' \
            | sort | head -n $((n - KEEP)))
  if [ -n "$deleted" ]; then
    (cd "$dir" && rm -f $deleted)
    log "pruned $(echo "$deleted" | wc -l) old archive(s) from $dir"
  fi
}

prune "$LOCAL_DIR"

# Off-host guarantee.  The NAS used to be the second copy; it is retired, so
# check the bucket instead.  Reading the repository does not take a lock, so
# this stays safe even while the nightly run is still uploading.
s3_fresh() {
  local newest epoch age
  if [ ! -r "$RESTIC_ENV" ]; then
    echo "ERROR: $RESTIC_ENV is missing, the off-host copy cannot be verified" >&2
    echo "       (see scratch/install-px-s3-backup.sh for how to recreate it)" >&2
    return 1
  fi
  if ! command -v restic >/dev/null; then
    echo "ERROR: restic is not installed, the off-host copy cannot be verified" >&2
    return 1
  fi
  (
    set -a; . "$RESTIC_ENV"; set +a
    # The bucket repository has an empty passphrase, which restic only accepts
    # together with --insecure-no-password and never together with a password
    # from the environment -- hence the unset.
    unset RESTIC_PASSWORD
    newest=$(timeout 300 restic --insecure-no-password snapshots --json --no-lock \
             --tag host 2>/dev/null \
             | tr , \n | sed -n 's/.*"time":"\([^"]*\)".*/\1/p' | sort | tail -1)
    [ -n "$newest" ] || { echo "ERROR: the repository has no snapshot tagged host" >&2; exit 1; }
    epoch=$(date -d "$newest" +%s) || { echo "ERROR: cannot read the snapshot time $newest" >&2; exit 1; }
    age=$(( $(date +%s) - epoch ))
    if [ "$age" -gt $(( MAX_AGE_HOURS * 3600 )) ]; then
      echo "ERROR: newest host snapshot in the bucket is $(( age / 3600 )) h old" >&2
      echo "       (px-s3-backup.service failed or did not run; check: journalctl -u px-s3-backup.service)" >&2
      exit 1
    fi
    log "off-host copy is fresh: host snapshot from $newest ($(( age / 60 )) min ago)"
  )
}

if ! s3_fresh; then
  fail=1
fi

exit $fail
