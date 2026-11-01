#!/bin/bash
export PATH=/run/current-system/sw/bin:/run/current-system/bin:/usr/bin:/bin
# One-off migration tooling for the Nextcloud -> Garage S3 primary-storage
# switch (2026-10-31).  Kept for reproducibility: re-running the copy is how a
# delta pass is done, and nc-s3-inventory.php is how the bucket is reconciled
# against oc_filecache.
#
# NOTE: these scripts reference the Nix store paths of Nextcloud 33.0.10 and its
# bundled PHP/AWS SDK, which change on every upgrade.  Resolve them again with:
#     readlink -f "$(command -v nextcloud-occ)"   # or: systemctl cat phpfpm-nextcloud
# They expect /var/lib/nc-s3-migration/{manifest.tsv,creds.json} and run as the
# nextcloud user.  See README.md ("Nextcloud user files on Garage S3").
PHP=/nix/store/sfrha54dgcgkrpwmyw6z9xwv22aayfsr-php-with-extensions-8.4.27/bin/php
STATE=/var/lib/nc-s3-migration
K=${1:-8}
unset NC_MANIFEST NC_DATADIR
echo "START $(date -Is) workers=$K manifest=$(wc -l < $STATE/manifest.tsv) lines"
for i in $(seq 0 $((K - 1))); do
  su -s /run/current-system/sw/bin/bash nextcloud -c "$PHP $STATE/nc-s3-copy.php --worker=$i --workers=$K" &
done
wait
echo "ALL_DONE $(date -Is)"
grep -h FINAL $STATE/progress-w*.txt
echo "done_total=$(cat $STATE/done-w*.txt 2>/dev/null | wc -l) failed_total=$(cat $STATE/failed-w*.tsv 2>/dev/null | wc -l)"
