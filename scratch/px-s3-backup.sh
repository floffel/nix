#!/bin/bash
#
# Off-host backup of the Proxmox host and every guest into the Garage S3
# bucket "pxbackup" (a restic repository).
#
# Why this exists: the vzdump job wrote its archives to the NAS over NFS and
# the NAS is going away.  "Copy the dump directory to a bucket" is not an
# option here -- a full nightly run is far bigger than the host's root disk,
# so there is nowhere to stage it.  Instead every guest is streamed straight
# out of vzdump into restic, which compresses and deduplicates on the way and
# keeps a retention policy inside the bucket.
#
# What is backed up per run (three kinds of snapshot group, see RETENTION):
#   host      the files no vzdump job covers: /var/lib/secrets (the shared
#             secrets), the pmxcfs configs behind /etc/pve (LXC configs,
#             storage.cfg, jobs.cfg, ...), host network/SSH/systemd config,
#             /usr/local/sbin, /root/backups and the restic credentials
#             themselves.
#   guest-N   one vzdump stream per guest, uncompressed (restic compresses),
#             stored as vzdump/vzdump-<type>-<vmid>-<date>.tar(.vma).
#
# There is deliberately NO repository password: the bucket is trusted (Garage is
# reachable only from the internal network and is backed up in its own right at
# the destination), so the master key is stored with an empty passphrase and
# every restic call carries --insecure-no-password.  Consequence: whoever holds
# the Garage key can read every dump, including all TLS keys and DB passwords.
# To put encryption back:
#   restic --insecure-no-password key add --new-password-file /path/to/pw
# then store that password in /etc/px-backup.env and drop the flag again.
#
# Two properties are deliberate:
#   * nothing is staged on disk: restic runs vzdump itself (--stdin-from-command),
#     so the job needs no free space proportional to the data it backs up.  The
#     host only has 32 G of tmpfs, and a full nightly run is far bigger;
#   * a guest only counts as backed up when vzdump exited 0 *and* restic
#     recorded a snapshot of a plausible size, so a truncated stream fails the
#     run instead of quietly becoming a short backup.
#
# Usage:
#   px-s3-backup.sh                 full run (host files + all guests + retention)
#   px-s3-backup.sh --host-only     skip the guests
#   px-s3-backup.sh --guests-only   skip the host files
#   px-s3-backup.sh --guest 108     only this guest (repeatable; implies --guests-only)
#   px-s3-backup.sh --no-forget     upload, but keep/delete nothing
#   px-s3-backup.sh --dry-run       change nothing (implies --no-forget)
#
# Exit: 0 only if every step succeeded.  Any failed guest fails the run.

set -uo pipefail

ENV_FILE=/etc/px-backup.env

# Retention, applied per snapshot group.  Grouping is by tag, so every guest
# keeps its own history and one guest's data can never be pruned by another's.
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
KEEP_YEARLY=2

# Structural check on every run; a real data read on Sundays.
CHECK_READ_DATA_SUBSET=5

# Repacking old packs is the expensive part of pruning; bound it per night.
MAX_REPACK=5G

# Everything a host rebuild needs that is not in this git repository.
PATHS=(
  /var/lib/secrets
  /var/backups/host-secrets
  /var/lib/vz/dump
  /etc/pve/nodes
  /etc/pve/storage.cfg
  /etc/pve/jobs.cfg
  /etc/pve/user.cfg
  /etc/pve/datacenter.cfg
  /etc/pve/authkey.pve
  /etc/pve/priv
  /etc/network/interfaces
  /etc/hosts
  /etc/fstab
  /etc/chrony
  /etc/ssh
  /etc/corosync
  /etc/systemd/system
  /etc/rclone-pxbackup.conf
  "$ENV_FILE"
  /usr/local/sbin
  /root/backups
)

MODE=all
DRY_RUN=0
RUN_FORGET=1
ONLY_GUESTS=()

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host-only)    MODE=host; shift ;;
    --guests-only)  MODE=guests; shift ;;
    --guest)        MODE=guests; ONLY_GUESTS+=("$2"); shift 2 ;;
    --no-forget)    RUN_FORGET=0; shift ;;
    --dry-run)      DRY_RUN=1; RUN_FORGET=0; shift ;;
    -h|--help)      sed -n '/^# Off-host backup/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- preflight ---

if [ "$(id -u)" != "0" ]; then echo "run as root" >&2; exit 1; fi

if [ ! -r "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE is missing or unreadable.  It holds RESTIC_REPOSITORY" >&2
  echo "       and the Garage key for the pxbackup bucket (no password; the" >&2
  echo "       repository key has an empty passphrase); see" >&2
  echo "       scratch/install-px-s3-backup.sh for how to (re)create it." >&2
  exit 1
fi
set -a; . "$ENV_FILE"; set +a

for v in RESTIC_REPOSITORY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if [ -z "${!v:-}" ]; then echo "ERROR: $v is not set in $ENV_FILE" >&2; exit 1; fi
done
command -v restic >/dev/null || { echo "ERROR: restic not in PATH" >&2; exit 1; }

# Empty repository password (see the header).  restic refuses to combine the
# flag with a password from the environment, so a leftover RESTIC_PASSWORD here
# is a hard error rather than a silent fallback.
if [ -n "${RESTIC_PASSWORD:-}" ]; then
  echo "ERROR: $ENV_FILE still sets RESTIC_PASSWORD, but this repository is opened" >&2
  echo "       with an empty password (--insecure-no-password).  Remove the line." >&2
  exit 1
fi
RESTIC=(restic --insecure-no-password)

STAMP=$(date +%F)
fail=0
FAILED_GUESTS=()

# A run that died can leave a lock that blocks forget/prune forever.
timeout 120 "${RESTIC[@]}" unlock >/dev/null 2>&1 || true

if ! timeout 180 "${RESTIC[@]}" cat config >/dev/null 2>&1; then
  echo "ERROR: cannot open the restic repository at $RESTIC_REPOSITORY" >&2
  echo "       (Garage reachable?  Garage key still valid?)" >&2
  exit 1
fi
log "repository: $(timeout 120 "${RESTIC[@]}" cat config | tr -d ' \n' | head -c 100)"

# Sets SNAP_ID from the JSON summary of `restic backup`; empty on failure.
SNAP_ID=""
run_backup() {
  local out
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN restic backup $*"
    SNAP_ID=""
    return 0
  fi
  out=$("${RESTIC[@]}" backup --json "$@" | tail -n 1)
  SNAP_ID=$(printf '%s' "$out" | sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p')
  [ -n "$SNAP_ID" ] || { echo "ERROR: restic backup failed: $out" >&2; return 1; }
  return 0
}

# ------------------------------------------------------------- host config ---

if [ "$MODE" != guests ]; then
  RESOLVED=()
  for p in "${PATHS[@]}"; do
    if [ -e "$p" ] || [ -L "$p" ]; then RESOLVED+=("$p"); fi
  done
  if [ ${#RESOLVED[@]} -eq 0 ]; then
    echo "ERROR: none of the configured host paths exist" >&2
    exit 1
  fi
  log "host files: ${#RESOLVED[@]} paths"
  if run_backup --tag host --exclude-caches "${RESOLVED[@]}"; then
    log "host files: snapshot ${SNAP_ID:-dry-run}"
    # Invariant: every requested path must appear in the snapshot.  /etc/pve is
    # pmxcfs (FUSE); a broken mount there would otherwise store an empty
    # directory instead of the configs, silently.
    if [ "$DRY_RUN" -eq 0 ] && [ -n "$SNAP_ID" ]; then
      LISTING=$(timeout 300 "${RESTIC[@]}" ls "$SNAP_ID" 2>/dev/null)
      for p in "${RESOLVED[@]}"; do
        if ! printf '%s\n' "$LISTING" | grep -qF -- "$p"; then
          echo "ERROR: snapshot $SNAP_ID has no entry for $p" >&2
          fail=1
        fi
      done
    fi
  else
    echo "ERROR: the host-file backup failed" >&2
    fail=1
  fi
fi

# ------------------------------------------------------------------- guests ---

if [ "$MODE" != host ]; then
  # /cluster/resources is the only list that also marks templates, and it is
  # what tells an LXC guest apart from a qemu one (which changes the archive
  # extension and therefore the restore command).
  # Deliberately free of double quotes inside the perl program (q()/qq() and
  # STDIN instead of open): the whole program sits in a single-quoted shell
  # string, and a stray quote there breaks the guest list silently.
  mapfile -t ALL_GUESTS < <(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | perl -MJSON::PP -0777 -E '
        my $d = decode_json(<STDIN>);
        for my $r (sort { $a->{vmid} <=> $b->{vmid} } @$d) {
          next if $r->{template};
          say join(q( ), $r->{type}, $r->{vmid}, ($r->{name} // qq(vm$r->{vmid})));
        }')

  GUESTS=()
  if [ ${#ONLY_GUESTS[@]} -gt 0 ]; then
    for want in "${ONLY_GUESTS[@]}"; do
      matched=0
      for e in "${ALL_GUESTS[@]}"; do
        set -- $e
        if [ "$2" = "$want" ]; then GUESTS+=("$e"); matched=1; fi
      done
      if [ "$matched" -eq 0 ]; then
        echo "ERROR: no non-template guest with VMID $want" >&2
        exit 1
      fi
    done
  else
    GUESTS=("${ALL_GUESTS[@]}")
  fi
  if [ ${#GUESTS[@]} -eq 0 ]; then
    echo "ERROR: no guests to back up" >&2
    exit 1
  fi

  TOTAL=${#GUESTS[@]}
  OK=0
  for entry in "${GUESTS[@]}"; do
    set -- $entry
    gtype=$1; vmid=$2; gname=$3
    # vzdump names qemu archives .vma and LXC archives .tar; keep that, so a
    # restored object goes straight into qm restore / pct restore.
    case "$gtype" in
      qemu) ext=vma ;;
      *)    ext=tar; gtype=lxc ;;
    esac
    [ -n "$gname" ] || gname=vm$vmid
    # restic's --stdin-filename must not contain a "/": with a slash restic
    # tries to open that path as source and the snapshot fails.  The name is
    # therefore flat; the tags carry the grouping instead.
    archive="vzdump-${gtype}-${vmid}-${STAMP}.${ext}"

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN guest $vmid ($gname): restic backup --stdin-from-command --stdin-filename $archive -- vzdump $vmid --mode snapshot --stdout"
      continue
    fi

    log "guest $vmid ($gname): streaming -> $archive (tag guest-${vmid})"
    started=$(date +%s)
    rout=$(mktemp)
    # restic runs vzdump itself: nothing is ever written to disk (the host has
    # 32 G of tmpfs and a full nightly run is far bigger), and a failing vzdump
    # fails the snapshot with vzdump's own exit status.  vzdump's log arrives on
    # stderr, prefixed with "subprocess vzdump:".
    (
      set -o pipefail
      timeout 4h "${RESTIC[@]}" backup --json --stdin-from-command \
        --stdin-filename "$archive" --tag "guest-${vmid}" --tag vzdump \
        --host "$(hostname)" -- vzdump "$vmid" --mode snapshot --stdout
    ) > "$rout" 2>&1
    rc=$?
    result=$(tail -n 1 "$rout")
    vzsummary=$(grep -a 'subprocess vzdump: ERROR' "$rout" | tail -5)
    tar_bytes=$(printf '%s' "$result" | sed -n 's/.*"total_bytes_processed":\([0-9]*\).*/\1/p')
    rm -f "$rout"
    elapsed=$(( $(date +%s) - started ))
    snap=$(printf '%s' "$result" | sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p')

    if [ "$rc" -ne 0 ] || [ -z "$snap" ]; then
      echo "ERROR: guest $vmid ($gname) failed (rc=$rc, ${elapsed}s)" >&2
      printf '%s\n' "$result" | tail -c 300 >&2
      [ -n "$vzsummary" ] && printf '%s\n' "$vzsummary" >&2
      FAILED_GUESTS+=("$vmid"); fail=1
      continue
    fi
    # An empty archive is not a backup: every guest here holds gigabytes.
    if [ -z "${tar_bytes:-}" ] || [ "$tar_bytes" -lt 1048576 ]; then
      echo "ERROR: guest $vmid: restic read ${tar_bytes:-0} bytes, that is not a real dump" >&2
      FAILED_GUESTS+=("$vmid"); fail=1
      continue
    fi
    log "guest $vmid ($gname): snapshot ${snap:0:8}, ${tar_bytes:-?} bytes, ${elapsed}s"
    OK=$((OK + 1))
  done
  log "guests: $OK/$TOTAL ok"
  [ "$OK" -gt 0 ] || fail=1
  if [ ${#FAILED_GUESTS[@]} -gt 0 ]; then
    echo "ERROR: failed guests: ${FAILED_GUESTS[*]}" >&2
  fi
fi

# ----------------------------------------------------- retention + integrity ---

if [ "$RUN_FORGET" -eq 1 ]; then
  log "retention: keep-daily=$KEEP_DAILY keep-weekly=$KEEP_WEEKLY keep-monthly=$KEEP_MONTHLY keep-yearly=$KEEP_YEARLY, grouped by tag"
  if ! timeout 6h "${RESTIC[@]}" forget --prune --group-by tag \
        --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" --keep-yearly "$KEEP_YEARLY" \
        --max-repack-size "$MAX_REPACK"; then
    echo "ERROR: restic forget --prune failed" >&2
    fail=1
  fi

  log "integrity: structural check"
  if ! timeout 6h "${RESTIC[@]}" check; then
    echo "ERROR: restic check failed" >&2
    fail=1
  fi
  # Structural checks never prove the data reads back; do a slice of that weekly.
  if [ "$(date +%u)" = 7 ]; then
    log "integrity: Sunday read check over ${CHECK_READ_DATA_SUBSET}% of the repository"
    if ! timeout 12h "${RESTIC[@]}" check --read-data-subset="$CHECK_READ_DATA_SUBSET"%; then
      echo "ERROR: restic check --read-data-subset failed" >&2
      fail=1
    fi
  fi
fi

log "repository: $(timeout 300 "${RESTIC[@]}" stats --json 2>/dev/null \
     | perl -0ne 'my $s = /"total_size":(\d+)/ ? $1 : 0; my $n = /"total_file_count":(\d+)/ ? $1 : 0;
                  my $k = /"snapshots_count":(\d+)/ ? $1 : 0;
                  printf "%.1f GB, %d files, %d snapshots", $s/1073741824, $n, $k')"

if [ "$fail" -eq 0 ]; then
  log "backup finished successfully"
else
  echo "backup finished WITH ERRORS (see above)" >&2
fi
exit $fail
