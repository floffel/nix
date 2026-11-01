#!/bin/bash
# Part C of the Nextcloud -> Garage S3 switch: drop the NFS bind mount for the
# datadir.  Run on the PROXMOX HOST.
#
# This is possible because user file *content* now lives in the bucket; what
# remains on a datadir is config/, appdata/, the data-dir marker and per-user
# scratch dirs -- about 256 MB.  The NAS tree is only ever read, never modified,
# so it stays as the rollback path.
#
# THE TRAP (what the first attempt got wrong, and it nearly cost the install):
# CT 104's rootfs is the ZFS dataset `fast/subvol-104-disk-0`, which Proxmox
# mounts at /fast/subvol-104-disk-0 -- NOT at /var/lib/lxc/104/rootfs.  Writing
# to /var/lib/lxc/104/rootfs/... lands on the ext4 root and is invisible to the
# container.  The correct host-side path is /fast/subvol-104-disk-0/var/lib/...
#
# Why seed while the container is RUNNING: inside the container the target path
# is covered by the NFS bind mount, so anything written from the host stays
# hidden until the mount is gone.  That is exactly what we want -- the datadir is
# fully populated *before* the container ever boots without the mount.  Seeding
# it while stopped instead would boot Nextcloud with no config.php, and
# nextcloud-setup would then try maintenance:install against a populated database.
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

CT=104
ROOT=/fast/subvol-104-disk-0
NAS=/mnt/pve/nas/shared/nextcloud/data_new
DEST=$ROOT/var/lib/nextcloud-data
TS=$(date +%Y%m%d-%H%M)
BK=/root/backups/nextcloud-off-nas-$TS
CT_UID=100995   # nextcloud uid 995 in an unprivileged CT ("0 100000 65536")
CT_GID=100994   # nextcloud gid 994 -- NOT 995

fail() { echo "ABORT: $*"; exit 1; }
mkdir -p "$BK"
cp -a /etc/pve/lxc/$CT.conf "$BK/$CT.conf.pre-off-nas" || fail "cannot back up the container config"
echo "backup: $BK/$CT.conf.pre-off-nas"

[ -d "$NAS/config" ] || fail "NAS source $NAS is not there"

echo "=== assert the container currently reads the NAS copy, not the host path ==="
IN_SIZE=$(pct exec $CT -- /run/current-system/sw/bin/bash -lc "stat -c %s /var/lib/nextcloud-data/config/config.php" 2>/dev/null)
HOST_SIZE=$(stat -c %s "$DEST/config/config.php" 2>/dev/null || echo none)
pct exec $CT -- /run/current-system/sw/bin/bash -lc "mount" | grep -q "on /var/lib/nextcloud-data type nfs" \
  || fail "/var/lib/nextcloud-data is not an NFS mount inside the container"
echo "container (NFS) config.php=$IN_SIZE bytes; host path (hidden) config.php=$HOST_SIZE bytes"
[ "${IN_SIZE:-0}" -gt 1000 ] || fail "the live config.php looks wrong ($IN_SIZE bytes)"
if [ "$IN_SIZE" = "$HOST_SIZE" ]; then
  fail "the host path is the same file the container is using -- wrong path, refusing to continue"
fi

echo "=== seed the container's own datadir (invisible until the mount is gone) ==="
rm -rf "${DEST:?}/config" "${DEST:?}/data"
mkdir -p "$DEST/config" "$DEST/data"
cp -a "$NAS/config/." "$DEST/config/" || fail "copying config/ failed"
cp -a "$NAS/data/appdata_oc5veetcuvee" "$DEST/data/" || fail "copying appdata failed"
# NC 33 writes .ncdata, older releases .ocdata; the data-dir marker is not optional
for f in .ncdata .ocdata .htaccess index.html nextcloud.log; do
  if [ -e "$NAS/data/$f" ]; then
    cp -a "$NAS/data/$f" "$DEST/data/$f" || fail "copying $f failed"
  fi
done
if [ -d "$NAS/store-apps" ]; then
  cp -a "$NAS/store-apps" "$DEST/store-apps"
fi
# scratch/transfer skeletons; Nextcloud creates anything else on demand.
# files/ and files_versions/ are deliberately NOT copied: the object store
# serves them, and the NAS copy stays intact as the rollback path.
for u in "$NAS"/data/*@*; do
  name=$(basename "$u")
  for s in cache uploads files_versions; do
    mkdir -p "$DEST/data/$name/$s"
  done
done
chown -R $CT_UID:$CT_GID "$DEST"
echo "seeded: $(du -sh "$DEST" | cut -f1)"
echo "  config.php: $(stat -c %s "$DEST/config/config.php") bytes (should match the NFS size above)"
echo "  datadir:    $(ls -A "$DEST/data" | tr '\n' ' ')"

echo "=== remove the NFS bind mount (live section only, snapshot sections untouched) ==="
python3 - "$CT" <<'PY' || fail "could not edit the mount entry"
import sys
ct = sys.argv[1]
p = f"/etc/pve/lxc/{ct}.conf"
lines = open(p).read().splitlines(keepends=True)
out, removed, in_live = [], 0, True
for line in lines:
    if line.startswith("["):
        in_live = False          # everything after this belongs to a stored snapshot
    if in_live and removed == 0 and line.startswith("lxc.mount.entry") and "nextcloud/data_new" in line:
        removed += 1
        print("removing:", line.strip())
        continue
    out.append(line)
if removed != 1:
    sys.exit(f"expected to remove exactly 1 live mount line, removed {removed}")
open(p, "w").writelines(out)
PY

echo "=== restarting CT $CT (brief outage for cloud.minnecker.com and the proxy) ==="
pct stop $CT || fail "pct stop failed -- restore $BK/$CT.conf.pre-off-nas and start the container"
pct start $CT || fail "pct start failed -- restore $BK/$CT.conf.pre-off-nas and start the container"

echo "=== verifying ==="
for i in $(seq 1 30); do
  if pct exec $CT -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; systemctl is-active --quiet phpfpm-nextcloud"; then
    break
  fi
  sleep 5
done
pct exec $CT -- /run/current-system/sw/bin/bash -lc "
export PATH=/run/current-system/sw/bin:/run/current-system/bin:/usr/bin:/bin
echo -n 'NFS datadir mount: '; (mount | grep -q 'on /var/lib/nextcloud-data type nfs' && echo 'STILL THERE') || echo 'gone (good)'
echo -n 'filesystem behind it: '; stat -f -c %T /var/lib/nextcloud-data
nextcloud-occ status 2>&1 | grep -E 'installed|maintenance' | tr -s ' '
echo -n 'objectstore lines in override.config.php: '; grep -c objectstore /var/lib/nextcloud-data/config/override.config.php
echo -n 'datadir contents: '; ls -A /var/lib/nextcloud-data/data | tr '\n' ' '; echo
nextcloud-occ config:system:get datadirectory"
echo
echo "DONE at $(date +%H:%M:%S)"
echo "Rollback: cp $BK/$CT.conf.pre-off-nas /etc/pve/lxc/$CT.conf && pct stop $CT && pct start $CT"
