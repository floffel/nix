#!/bin/bash
#
# Retire the NAS from the containers: move every secret that is still read from
# /mnt/pve/nas/shared/secrets to the place it belongs, and rewrite the LXC bind
# entries accordingly.  Nothing here deletes or moves NAS data -- the share is
# only ever read from, so every step is reversible by restoring the LXC config.
#
# Placement rule (see README, "Where secrets live: host disk vs NAS share"):
#   shared between containers  -> the host's own disk, /var/lib/secrets/<group>,
#                                 bind-mounted into each consumer as before;
#   used by exactly one        -> that container's own filesystem (the mount
#   container                     entry disappears, the files move inside);
#   read by nobody             -> the mount entry disappears, the files are
#                                 archived under /root/backups.
#
# Why the host disk and not the NAS: /var/lib/secrets is on the host's root
# dataset, which px-s3-backup.sh backs up to Garage, and it removes the NAS
# from the boot path of every container (a mount entry whose source is gone
# makes `pct start` fail).
#
# Usage (on the Proxmox host, as root):
#   secrets-off-nas.sh --status              what still depends on the NAS
#   secrets-off-nas.sh --prepare             copy shared groups to the host disk
#   secrets-off-nas.sh --plan   <vmid>       show the new config, change nothing
#   secrets-off-nas.sh --apply  <vmid>       rewrite + restart + verify one CT
#   secrets-off-nas.sh --verify   <vmid>     re-run the checks only
#   secrets-off-nas.sh --reseed   <vmid>     re-copy a "container" group into a
#                                            container that was already migrated
#
# Apply order used on 2026-11-01 (leaf consumers first, infrastructure last):
#   113 111 110 102 106 101 103 109 105 104 107
#
# Every --apply is reversible:
#   cp /root/backups/<stamp>/<vmid>.conf.before /etc/pve/lxc/<vmid>.conf
#   pct stop <vmid> && pct start <vmid>

set -uo pipefail

NAS_ROOT=/mnt/pve/nas/shared/secrets
HOST_ROOT=/var/lib/secrets
STAMP=off-nas-$(date +%Y%m%d)
BACKUP_ROOT=/root/backups/$STAMP

# Where each NAS group goes.  Anything missing here is treated as unknown and
# makes --plan/--apply refuse to continue, so a new NAS group cannot be
# silently dropped.
declare -A DEST=(
  [ssl]=host
  [oauth2]=host
  [postgres]=host
  [redis]=host
  [mail]=host
  [nginx]=container
  [nsd]=container
  # no consumer any more: the runner keeps its token inside nixforgejo-runner,
  # and the coturn secret moved to the host disk on 2026-10-31
  [forgejo]=archive
  [coturn]=archive
  [crowdsec]=archive
  [nixvpn]=archive
  [wireguard]=archive
)

# Writer-side ownership on the host disk.  Container root is host uid 100000
# (every container maps 0 -> 100000), so files seeded as host root would be
# owned by "nobody" inside the containers.  The postgres provisioning unit runs
# as postgres (uid 71 in CT 107), so that group belongs to host 100071.
OWNER_container=100000
declare -A GROUP_OWNER=([postgres]=100071)

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die 'run as root'

ct_shell() {   # run a command line inside a NixOS container
  local vmid=$1; shift
  pct exec "$vmid" -- /run/current-system/sw/bin/bash -c \
    "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; $*" 2>&1
}

# A .conf file holds the live config *and* one section per snapshot
# ("[snapname]").  Only the live section -- everything before the first "[",
# which is what `pct config` prints -- means anything to a container start, so
# every read and write below is scoped to it.  Getting this wrong loses the
# mount entries silently: they end up in the snapshot section and the container
# boots without any secrets.
live_section() { awk '/^\[/{exit} {print}' "/etc/pve/lxc/$1.conf"; }
snap_sections() { awk '/^\[/{f=1} f' "/etc/pve/lxc/$1.conf"; }

# Unique mount entries of the live config, first-seen order, duplicates
# collapsed (repeated `pct set` calls had piled every entry up 2-4 times).
mount_entries() {
  live_section "$1" | awk '/^lxc\.mount\.entry:/{ if (!seen[$0]++) print }'
}

# Same, from a saved file instead of the live config -- needed after --apply has
# already rewritten the config, e.g. to seed a container group again.
mount_entries_file() {
  awk '/^\[/{exit} /^lxc\.mount\.entry:/{ if (!seen[$0]++) print }' "$1"
}

nas_entries() { mount_entries "$1" | grep -- "$NAS_ROOT" || true; }

# NAS source -> new source on the host disk; empty output for entries that
# disappear (files move into the container / are archived instead).
map_src() {
  local src=$1 trailing='' rel grp kind
  case "$src" in */) trailing=/ ;; esac
  src=${src%/}
  rel=${src#"$NAS_ROOT"/}
  grp=${rel%%/*}
  kind=${DEST[$grp]:-unknown}
  case "$kind" in
    host)  printf '%s/%s%s\n' "$HOST_ROOT" "$rel" "$trailing" ;;
    container|archive) printf '\n' ;;
    *) echo "unknown NAS group: $grp (from $src)" >&2; return 1 ;;
  esac
}

# The complete replacement set of mount entries for a container: host-disk
# versions of the NAS entries (parents before nested overrides, because LXC
# mounts in config order) plus every entry that never pointed at the NAS.
new_mount_entries() {
  local vmid=$1 n=0 out=() line kw src dst rest new
  local -A keep_dst=()

  # Pre-pass: which destinations does this container already mount from the
  # host disk?  Those lines are the live ones (verified when the group moved
  # there), so a NAS line for the same destination is a leftover to delete, not
  # a second mount to add -- mounting the same target twice makes the container
  # fail to start.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r kw src dst rest <<< "$line"
    if [ "$src" != "${src#"$NAS_ROOT"/}" ] || [ "$src" = "$NAS_ROOT" ]; then continue; fi
    keep_dst[${dst%/}]=1
  done <<< "$(mount_entries "$vmid")"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r kw src dst rest <<< "$line"
    if [ "$src" = "${src#"$NAS_ROOT"/}" ] && [ "$src" != "$NAS_ROOT" ]; then
      # Not NAS-backed: carried over unconditionally.  Only NAS lines are ever
      # dropped, and only in favour of a host-disk line for the same target.
      keep_dst[${dst%/}]=1
      out+=("${dst%/}"$'\t'"$n"$'\t'"$line"); n=$((n+1)); continue
    fi
    new=$(map_src "$src") || return 1
    [ -n "$new" ] || continue
    [ -n "${keep_dst[${dst%/}]:-}" ] && continue
    keep_dst[${dst%/}]=1
    out+=("${dst%/}"$'\t'"$n"$'\t'"lxc.mount.entry: $new $dst none ${rest#none }")
    n=$((n+1))
  done <<< "$(mount_entries "$vmid")"
  # Columns: dst, index-at-first-sight, entry.  Sort by path depth (so a parent
  # mount always precedes a nested override, which is what LXC mounts in) and
  # then by the original index, and hand out only the entry column.
  printf '%s\n' "${out[@]}" | awk -F'\t' 'NF>2' \
    | awk -F'\t' '{d=$1; n=gsub(/\//,"/",d); print n+1 "\t" $2 "\t" $3}' \
    | sort -t$'\t' -k1,1n -k2,2n | cut -f3-
}

# Full new config: live section without the old mount entries, then the new
# ones, then the snapshot sections exactly as they were.
build_conf() {
  local vmid=$1
  live_section "$vmid" | grep -v '^lxc\.mount\.entry:'
  new_mount_entries "$vmid"
  snap_sections "$vmid"
}

seed_into_container() {  # vmid config-the-entries-came-from
  local vmid=$1 srccfg=$2 ds pool vol mnt line kw src dst rest rel grp
  ds=$(pct config "$vmid" | awk '/^rootfs:/{print $2}'); ds=${ds%%,*}
  pool=${ds%%:*}; vol=${ds#*:}; mnt=/$pool/$vol
  mountpoint -q "$mnt" || zfs mount "$pool/$vol" 2>/dev/null || true
  mountpoint -q "$mnt" || die "$mnt is not mounted; cannot seed files into CT $vmid"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r kw src dst rest <<< "$line"
    rel=${src#"$NAS_ROOT"/}; rel=${rel%/}
    grp=${rel%%/*}
    [ "${DEST[$grp]:-}" = container ] || continue
    dst=${dst%/}
    if [ -d "$src" ]; then
      mkdir -p "$mnt/$dst" && cp -a "$src/." "$mnt/$dst/" \
        && chown -R "$OWNER_container:$OWNER_container" "$mnt/$dst" \
        && log "  seeded $dst ($(find "$mnt/$dst" -type f | wc -l) files) into CT $vmid" \
        || die "could not seed $dst into CT $vmid"
    else
      mkdir -p "$(dirname "$mnt/$dst")" && cp -a "$src" "$mnt/$dst" \
        && chown "$OWNER_container:$OWNER_container" "$mnt/$dst" \
        && log "  seeded $dst into CT $vmid" || die "could not seed $dst"
    fi
  done <<< "$(mount_entries_file "$srccfg" | grep -- "$NAS_ROOT" || true)"
}

reseed_ct() {  # re-run only the seeding step for an already-migrated container
  local vmid=$1 saved
  saved="$BACKUP_ROOT/$vmid.conf.before"
  [ -r "$saved" ] || die "no saved config for CT $vmid under $BACKUP_ROOT"
  pct status "$vmid" | grep -q stopped || die 'stop the container first: its own filesystem is written directly'
  seed_into_container "$vmid" "$saved"
}

# Ownership on the host disk must mirror the NAS byte for byte, with one
# substitution: uid/gid 0 (the NAS stores container-root writes as host root,
# which is *unmapped* inside a container and shows up as "nobody") becomes the
# container-side owner.  Everything else -- rspamd 100225, postfix 100013,
# dovecot 100995 -- is a real container user and has to stay as it is, or that
# service can no longer read its own key.
sync_owners() {  # group target-owner
  local grp=$1 owner=$2 src="$NAS_ROOT/$grp" dst="$HOST_ROOT/$grp" f rel u g
  [ -d "$src" ] || return 0
  # rsync -a copies the source directory itself, so the group directory ends up
  # owned by host root like it was on the NAS; that is unmapped inside every
  # container, so it belongs to the writer as well.
  chown "$owner:$owner" "$dst"
  while IFS= read -r -d '' f; do
    rel=${f#"$src"/}
    [ -e "$dst/$rel" ] || continue
    u=$(stat -c %u "$f"); g=$(stat -c %g "$f")
    [ "$u" = 0 ] && u=$owner
    [ "$g" = 0 ] && g=$owner
    chown "$u:$g" "$dst/$rel" 2>/dev/null
  done < <(find "$src" -mindepth 1 -print0)
}

prepare_host_disk() {
  local grp rel owner
  [ -d "$NAS_ROOT" ] || die "$NAS_ROOT is not mounted"
  mkdir -p "$HOST_ROOT" "$BACKUP_ROOT/nas-archive"
  for grp in "${!DEST[@]}"; do
    [ "${DEST[$grp]}" = host ] || continue
    [ -d "$NAS_ROOT/$grp" ] || { log "group $grp: not on the NAS, skipped"; continue; }
    owner=${GROUP_OWNER[$grp]:-$OWNER_container}
    # --ignore-existing: values that already live on the host disk are the live
    # ones (the matrix subdirs moved there first) and must never be replaced by
    # a stale NAS copy.
    install -d -m 755 -o "$owner" -g "$owner" "$HOST_ROOT/$grp"
    if rsync -a --ignore-existing "$NAS_ROOT/$grp/" "$HOST_ROOT/$grp/"; then
      sync_owners "$grp" "$owner"
      log "group $grp: copied to $HOST_ROOT/$grp ($(find "$HOST_ROOT/$grp" -type f | wc -l) files)"
    else
      die "rsync failed for group $grp"
    fi
  done
  for grp in "${!DEST[@]}"; do
    [ "${DEST[$grp]}" = archive ] || continue
    [ -e "$NAS_ROOT/$grp" ] || continue
    cp -a "$NAS_ROOT/$grp" "$BACKUP_ROOT/nas-archive/" \
      && log "group $grp: archived to $BACKUP_ROOT/nas-archive/$grp"
  done
}

verify_ct() {
  local vmid=$1 nascount bad=0 line kw src dst rest rel expect
  pct status "$vmid" | grep -q running || { echo "ERROR: CT $vmid is not running" >&2; return 1; }
  # The NAS is an NFS export, so inside the container the *source* reads as
  # "192.168.1.203:/mnt/big/remote/..." and never contains /mnt/pve/nas -- the
  # filesystem type is what identifies it.
  nascount=$(ct_shell "$vmid" 'awk "\$3==\"nfs\"||\$3==\"nfs4\"{n++} END{print n+0}" /proc/mounts' | tail -1)
  if [ "${nascount:-0}" != 0 ]; then
    echo "ERROR: CT $vmid still has $nascount NFS mount(s) (the NAS):" >&2
    ct_shell "$vmid" 'awk "\$3==\"nfs\"||\$3==\"nfs4\"" /proc/mounts' >&2
    bad=1
  else
    log "CT $vmid: no NFS (NAS) mounts inside"
  fi
  # Every secret path the config still declares must exist and be non-empty.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r kw src dst rest <<< "$line"
    expect="$dst"
    target=/${expect#/}
    found=$(ct_shell "$vmid" "find $target -type f -print -quit" | tail -1)
    if [ -z "$found" ]; then
      echo "ERROR: $dst is empty or missing inside CT $vmid" >&2; bad=1
    fi
  done <<< "$(mount_entries "$vmid")"
  local failed
  failed=$(ct_shell "$vmid" 'systemctl --failed --no-legend --no-pager' | grep -c . || true)
  log "CT $vmid: $failed failed unit(s) [$(ct_shell "$vmid" 'systemctl is-system-running' | tail -1)]"
  [ "$failed" = 0 ] || ct_shell "$vmid" 'systemctl --failed --no-legend --no-pager' | head -10
  return $bad
}

status_all() {
  local id n h
  printf '%-5s %-20s %-6s %-5s %s\n' CT name status NAS host
  for id in $(pct list | awk 'NR>1{print $1}' | sort -n); do
    n=$(nas_entries "$id" | wc -l)
    h=$(mount_entries "$id" | grep -vc -- "$NAS_ROOT" || true)
    printf '%-5s %-20s %-6s %-5s %s\n' "$id" "$(pct config "$id" | awk '/^hostname:/{print $2}')" \
      "$(pct status "$id" | awk '{print $2}')" "$n" "$h"
  done
}

plan_ct() {
  local vmid=$1 nas line kw src dst rest rel
  echo "== CT $vmid ($(pct config "$vmid" | awk '/^hostname:/{print $2}')) =="
  nas=$(nas_entries "$vmid")
  if [ -z "$nas" ]; then echo "  no NAS entries"; return 0; fi
  echo "  NAS entries today (duplicates collapsed):"
  printf '%s\n' "$nas" | sed 's/^/    /'
  echo "  becomes:"
  new_mount_entries "$vmid" | sed 's/^/    /'
  echo "  files moving into the container itself:"
  printf '%s\n' "$nas" | while IFS= read -r line; do
    read -r kw src dst rest <<< "$line"
    rel=${src#"$NAS_ROOT"/}; rel=${rel%/}
    key=${rel%%/*}
    case "${DEST[$key]:-}" in
      container) echo "    $src -> CT $vmid:$dst" ;;
      archive)   echo "    $src -> archived only (nothing reads it)" ;;
    esac
  done
}

apply_ct() {
  local vmid=$1 conf new nas ds pool vol
  [ "$vmid" = 100 ] && die 'CT 100 (nixwireguard) is the network edge and must not be restarted from a remote session (AGENTS.md)'
  conf=/etc/pve/lxc/$vmid.conf
  [ -r "$conf" ] || die "no such container: $vmid"
  nas=$(nas_entries "$vmid")
  if [ -z "$nas" ]; then log "CT $vmid: no NAS entries, nothing to do"; return 0; fi
  new=$(build_conf "$vmid") || die 'could not build the new config'

  mkdir -p "$BACKUP_ROOT"
  cp -a "$conf" "$BACKUP_ROOT/$vmid.conf.before" || die 'could not save the old config'
  log "CT $vmid: old config saved to $BACKUP_ROOT/$vmid.conf.before"

  # "rootfs: fast:subvol-113-disk-0,size=16G" -- drop the options and turn the
  # Proxmox storage id into the ZFS dataset name (colon becomes a slash).
  ds=$(pct config "$vmid" | awk '/^rootfs:/{print $2}'); ds=${ds%%,*}
  if zfs list "${ds/://}" >/dev/null 2>&1; then
    zfs snapshot "${ds/://}@pre-$STAMP" && log "CT $vmid: snapshot ${ds/://}@pre-$STAMP" \
      || log "CT $vmid: could not snapshot ${ds/://} (continuing)"
  else
    log "CT $vmid: rootfs $ds is not a ZFS dataset, no pre-change snapshot"
  fi

  printf '%s\n' "$new" > "$BACKUP_ROOT/$vmid.conf.after" || die 'could not write the staged config'
  # Refuse an obviously broken replacement: the container identity must survive.
  grep -q '^hostname:' "$BACKUP_ROOT/$vmid.conf.after" || die 'staged config lost the hostname line'
  grep -q '^rootfs:'   "$BACKUP_ROOT/$vmid.conf.after" || die 'staged config lost the rootfs line'

  log "CT $vmid: writing $conf"
  cp "$BACKUP_ROOT/$vmid.conf.after" "$conf" || die 'could not write the new config'
  sleep 1

  # What pmxcfs actually stored must match what was staged.  A config that
  # looks right in the file but lands in the wrong section is worse than no
  # change at all: the container comes up without its secrets.
  diff <(awk '/^\[/{exit} /^lxc\.mount\.entry:/' "$BACKUP_ROOT/$vmid.conf.after") \
       <(mount_entries "$vmid") > "$BACKUP_ROOT/$vmid.mounts.diff" \
    || { cat "$BACKUP_ROOT/$vmid.mounts.diff" >&2; die "live mount entries after the write differ from the staged ones"; }
  # Same for the remaining lines.  pmxcfs re-writes the file in its own order
  # and collapses duplicate list entries, so compare the set of lines, not the
  # exact text.
  norm() { grep -v '^lxc\.mount\.entry:' | grep -v '^[[:space:]]*$' | sort; }
  diff <(awk '/^\[/{exit} {print}' "$BACKUP_ROOT/$vmid.conf.after" | norm) \
       <(live_section "$vmid" | norm) > "$BACKUP_ROOT/$vmid.other.diff" \
    || { cat "$BACKUP_ROOT/$vmid.other.diff" >&2; die "non-mount config lines changed unexpectedly"; }
  log "CT $vmid: live config verified ($(mount_entries "$vmid" | wc -l) mount entries, no other line changed)"

  log "CT $vmid: stopping"
  timeout 180 pct stop "$vmid" || die "pct stop $vmid failed"
  pct status "$vmid" | grep -q stopped || die "CT $vmid did not stop"

  seed_into_container "$vmid" "$BACKUP_ROOT/$vmid.conf.before"

  log "CT $vmid: starting"
  timeout 180 pct start "$vmid" || die "pct start $vmid failed"
  sleep 5
  if verify_ct "$vmid"; then
    log "CT $vmid: OK"
  else
    echo "CT $vmid: verification reported problems (see above)." >&2
    echo "Rollback: cp $BACKUP_ROOT/$vmid.conf.before $conf; pct stop $vmid && pct start $vmid" >&2
    return 1
  fi
}

case "${1:-}" in
  --status)  status_all ;;
  --prepare) prepare_host_disk ;;
  --plan)    [ -n "${2:-}" ] || die '--plan needs a VMID'; plan_ct "$2" ;;
  --apply)   [ -n "${2:-}" ] || die '--apply needs a VMID'; apply_ct "$2" ;;
  --verify)  [ -n "${2:-}" ] || die '--verify needs a VMID'; verify_ct "$2" ;;
  --reseed)  [ -n "${2:-}" ] || die '--reseed needs a VMID'
             # pct stop exits non-zero when the container is already stopped.
             pct stop "$2" 2>/dev/null || true
             reseed_ct "$2"
             pct start "$2" ;;
  *) sed -n '/^# Retire the NAS/,/^# Every --apply is reversible/p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
