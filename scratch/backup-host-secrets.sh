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
# Two copies are written: one on the host, one on the NAS (the only off-host
# storage here). Retention is $KEEP archives in each place.
#
# Usage:  backup-host-secrets.sh [--keep N]
# Exit:   0 when both copies are OK, non-zero if either target failed.

set -uo pipefail

LOCAL_DIR=/var/backups/host-secrets
NAS_DIR=/mnt/pve/nas/shared/host-backups
NAS_MOUNT=/mnt/pve/nas
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

# Off-host copy. A missing NAS mount is a real backup failure, not a warning:
# the local copy alone does not survive loss of the host disk.
#
# /mnt/pve/nas is not in /etc/fstab: it is a Proxmox NFS storage with a
# generated mnt-pve-nas.mount unit, so it can be idle-unmounted. Try to
# activate it before giving up (the same way vzdump brings it up).
if ! mountpoint -q "$NAS_MOUNT"; then
  log "$NAS_MOUNT not mounted, asking systemd for mnt-pve-nas.mount"
  timeout 90 systemctl start mnt-pve-nas.mount 2>/dev/null || true
fi

if mountpoint -q "$NAS_MOUNT"; then
  if mkdir -p "$NAS_DIR" && cp "$LOCAL_FILE" "${NAS_DIR}/${ARCHIVE}.tmp" \
     && mv "${NAS_DIR}/${ARCHIVE}.tmp" "${NAS_DIR}/${ARCHIVE}" \
     && zstd -t "${NAS_DIR}/${ARCHIVE}" 2>/dev/null; then
    log "copied to ${NAS_DIR}/${ARCHIVE}"
    prune "$NAS_DIR"
  else
    rm -f "${NAS_DIR}/${ARCHIVE}.tmp"
    echo "ERROR: could not write ${NAS_DIR}/${ARCHIVE}" >&2
    fail=1
  fi
else
  echo "ERROR: $NAS_MOUNT is not mounted, no off-host copy was made" >&2
  fail=1
fi

exit $fail
