#!/bin/bash
# Cut-over step: make the bucket match oc_filecache *as of maintenance mode*.
#
# The warm copy ran against a manifest taken hours earlier, and a fileid is
# never rewritten when a file changes, so the delta pass needs a fresh
# manifest.  Also repairs every fileid that a previous pass recorded as failed
# -- and purges those ids from the done ledgers first, because the old copy
# script could mark a file done from a size-only HEAD match, which poisoned at
# least one ledger entry.
#
# Additive towards S3 (objects are only overwritten, never deleted) and it
# never touches the NAS tree.  See README.md.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/run/current-system/bin:/usr/bin:/bin
PHP=${PHP:-/nix/store/sfrha54dgcgkrpwmyw6z9xwv22aayfsr-php-with-extensions-8.4.27/bin/php}
S=/var/lib/nc-s3-migration
K=${1:-4}
T=$(printf '\t')

if [ ! -f "$S/manifest-new.tsv" ]; then
  echo "ABORT: $S/manifest-new.tsv missing (regenerate it from oc_filecache first)"
  exit 1
fi

echo "manifest: old=$(wc -l < "$S/manifest.tsv") fresh=$(wc -l < "$S/manifest-new.tsv")"

# fileids that a previous pass could not verify
cut -f1 "$S"/failed-w*.tsv 2>/dev/null | tr -dc '0-9\n' | sort -u > "$S/repair-ids.txt"
echo "previously failed: $(wc -l < "$S/repair-ids.txt")"

# the ledgers are no longer trustworthy for those ids
for f in "$S"/done-w*.txt; do
  [ -f "$f" ] || continue
  grep -vxF -f "$S/repair-ids.txt" "$f" > "$f.clean" && mv "$f.clean" "$f"
done
# this script runs as root, but the copy workers append to the ledgers as the
# nextcloud user -- rewriting them must not change their ownership
chown nextcloud:nextcloud "$S"/done-w*.txt

# delta = new fileids + size-changed fileids + previously failed fileids
awk -F"$T" 'NR==FNR {old[$1]=$4; next}
            {if (!($1 in old) || old[$1] != $4) print $1}' "$S/manifest.tsv" "$S/manifest-new.tsv" \
  | sort -u > "$S/delta-ids.txt"
cat "$S/repair-ids.txt" >> "$S/delta-ids.txt"
sort -u -o "$S/delta-ids.txt" "$S/delta-ids.txt"
awk -F"$T" 'NR==FNR {want[$1]=1; next} ($1 in want)' "$S/delta-ids.txt" "$S/manifest-new.tsv" > "$S/delta.tsv"
echo "delta files=$(wc -l < "$S/delta.tsv") bytes=$(awk -F"$T" '{b+=$4} END {printf "%.1f MB", b/1048576}' "$S/delta.tsv")"
head -10 "$S/delta.tsv"

# a failed copy is a hard gate later, so start from a clean slate
rm -f "$S"/failed-w*.tsv

if [ -s "$S/delta.tsv" ]; then
  for i in $(seq 0 $((K - 1))); do
    su -s /run/current-system/sw/bin/bash nextcloud \
      -c "NC_MANIFEST=$S/delta.tsv $PHP $S/nc-s3-copy.php --worker=$i --workers=$K --force" &
  done
  wait
  grep -h FINAL "$S"/progress-w*.txt
else
  echo "delta empty, nothing to copy"
fi

FAILED=$(cat "$S"/failed-w*.tsv 2>/dev/null | wc -l)
echo "delta_failed=$FAILED"
if [ "$FAILED" -ne 0 ]; then
  echo "ABORT: $FAILED objects still fail verification"
  cat "$S"/failed-w*.tsv
  exit 1
fi

# promote the fresh manifest so the reconcile gate compares against reality
mv "$S/manifest.tsv" "$S/manifest.tsv.warm"
mv "$S/manifest-new.tsv" "$S/manifest.tsv"
chown nextcloud:nextcloud "$S/manifest.tsv"
echo "manifest promoted"
