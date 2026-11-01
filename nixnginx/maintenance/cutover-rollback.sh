#!/bin/bash
# Emergency rollback of the Nextcloud S3 cut-over.  Requires the literal word
# CONFIRM so it cannot fire by accident.
#
#   ./cutover-rollback.sh CONFIRM
#
# Restores the pre-remap database and reverts the objectstore Nix change, then
# rebuilds CT 104.  The NFS datadir was never modified, so files are readable
# again as soon as the old storage ids are back.
set -uo pipefail
[ "${1:-}" = "CONFIRM" ] || { echo "usage: $0 CONFIRM  (refusing to run)"; exit 1; }
DUMP=/var/lib/nc-backups/nextcloud-pre-remap.dump
[ -f "$DUMP" ] || { echo "missing $DUMP"; exit 1; }

echo "### 1. restore the pre-remap database"
pct push 107 "$DUMP" /tmp/nextcloud-pre-remap.dump
pct exec 107 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; su -s /run/current-system/sw/bin/bash postgres -c 'pg_restore --clean --if-exists -d nextcloud /tmp/nextcloud-pre-remap.dump' 2>&1 | tail -5"
pct exec 107 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; su -s /run/current-system/sw/bin/bash postgres -c \"psql -d nextcloud -At -c \\\"SELECT id FROM oc_storages ORDER BY numeric_id\\\"\""

echo "### 2. revert the objectstore config"
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; cd /root/nixos-config && git revert --no-edit HEAD 2>&1 | tail -3"
rm -f /root/cutover-rollback-rebuild.log
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; bash /var/lib/nc-s3-migration/launch.sh nc-rollback-rebuild /root/cutover-rollback-rebuild.log /root/do-switch.sh"
for i in $(seq 1 60); do
  sleep 15
  st=$(pct exec 104 -- /run/current-system/sw/bin/bash -lc "systemctl is-active nc-rollback-rebuild"; true)
  [ "$st" = "activating" ] || { echo "rebuild done (state=$st)"; break; }
done
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; nextcloud-occ maintenance:mode --off; nextcloud-occ maintenance:mode; nextcloud-occ status | head -6"
echo "ROLLBACK COMPLETE $(date +%H:%M:%S) — note: git revert is local to the container; decide separately whether to push the revert."
