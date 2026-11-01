#!/bin/bash
# Nextcloud -> Garage S3 cut-over, part A (run on the Proxmox host).
# Stops writes, closes the copy, reconciles the bucket, remaps storage ids.
# Nothing here deletes data; rollback = restore the dumps in /var/lib/nc-backups.
set -uo pipefail
step() { echo; echo "########## $* — $(date +%H:%M:%S) ##########"; }

step "0. copy unit must be finished"
st=$(pct exec 104 -- /run/current-system/sw/bin/bash -lc "systemctl is-active nc-s3-copy"; true)
echo "nc-s3-copy: $st"
if [ "$st" = "activating" ] || [ "$st" = "active" ]; then
  echo "ABORT: copy still running"; exit 1
fi
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; tail -3 /var/lib/nc-s3-migration/copy.log"

step "1. final pg_dump (rollback point)"
pct exec 107 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; su -s /run/current-system/sw/bin/bash postgres -c 'pg_dump -Fc -d nextcloud -f /tmp/nextcloud-pre-remap.dump'"
pct pull 107 /tmp/nextcloud-pre-remap.dump /var/lib/nc-backups/nextcloud-pre-remap.dump
ls -l /var/lib/nc-backups/

step "2. maintenance mode ON"
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; nextcloud-occ maintenance:mode --on; nextcloud-occ maintenance:mode"

step "3. delta copy against a fresh manifest"
# Everything from here on runs with writes blocked, so this is the last chance
# to notice files that appeared or changed after the warm copy started.
T=$(printf '\t')
pct exec 107 -- /run/current-system/sw/bin/bash -lc "
export PATH=/run/current-system/sw/bin:/run/current-system/bin:/usr/bin:/bin
su -s /run/current-system/sw/bin/bash postgres -c \"psql -d nextcloud -A -F '$T' -At -P pager=off -c \\\"
  SELECT f.fileid, regexp_replace(s.id, '^home::', ''), f.path, f.size
  FROM oc_filecache f
  JOIN oc_storages s ON s.numeric_id = f.storage
  WHERE s.id LIKE 'home::%' AND f.mimetype <> 2
  ORDER BY f.size DESC, f.fileid\\\"\" > /tmp/nc-manifest-new.tsv
wc -l /tmp/nc-manifest-new.tsv"
pct pull 107 /tmp/nc-manifest-new.tsv /tmp/nc-manifest-new.tsv
pct push 104 /tmp/nc-manifest-new.tsv /var/lib/nc-s3-migration/manifest-new.tsv >/dev/null
pct push 104 /tmp/nc-s3-delta.sh /var/lib/nc-s3-migration/nc-s3-delta.sh >/dev/null
pct exec 104 -- /run/current-system/sw/bin/bash /var/lib/nc-s3-migration/nc-s3-delta.sh 4 2>&1 | tail -25
DELTA_RC=${PIPESTATUS[0]}
if [ "$DELTA_RC" -ne 0 ]; then
  echo "ABORT: delta/repair pass failed. Nothing written to the database; reopening."
  pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; nextcloud-occ maintenance:mode --off"
  exit 1
fi

step "4. inventory + reconcile"
pct push 104 /tmp/inventory.sh /var/lib/nc-s3-migration/inventory.sh >/dev/null
RECON=$(pct exec 104 -- /run/current-system/sw/bin/bash /var/lib/nc-s3-migration/inventory.sh 2>&1)
echo "$RECON" | tail -15
MISSING=$(echo "$RECON" | sed -nE 's/^missing=([0-9]+).*/\1/p' | head -1)
MISMATCH=$(echo "$RECON" | sed -nE 's/.*size_mismatch=([0-9]+).*/\1/p' | head -1)

if [ "${MISSING:-x}" != "0" ] || [ "${MISMATCH:-x}" != "0" ]; then
  echo "ABORT: bucket incomplete (missing=${MISSING:-?} size_mismatch=${MISMATCH:-?})."
  echo "Nothing has been written to the database; reopening the site."
  pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; nextcloud-occ maintenance:mode --off"
  exit 1
fi
echo "reconcile clean — safe to remap"

step "5. remap storage ids"
pct push 107 /tmp/remap-objectstore.sql /tmp/remap-objectstore.sql >/dev/null
pct exec 107 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; su -s /run/current-system/sw/bin/bash postgres -c 'psql -v ON_ERROR_STOP=1 -P pager=off -d nextcloud -f /tmp/remap-objectstore.sql'" 2>&1 | tail -40
echo
echo "PART A DONE at $(date +%H:%M:%S) — next: part B (rebuild + verify)"
