#!/bin/bash
#
# Install/refresh the S3 (Garage) backup on the Proxmox host.
# Run from the repository checkout, on the host, as root:
#
#   scratch/install-px-s3-backup.sh
#
# Idempotent: safe to re-run after every change to the script or the units.
#
# It does NOT create /etc/px-backup.env, because that file holds the Garage key.
# After a host rebuild recreate it like this (then re-run this installer):
#
#   umask 077
#   cat > /etc/px-backup.env <<'ENV'
#   # Garage bucket "pxbackup" (S3 endpoint of the dxflrs-garage container).
#   # The s3: URL must carry the http:// scheme: restic >= 0.17 assumes HTTPS
#   # for "s3:host:port/bucket", and Garage serves plaintext on :3900.
#   RESTIC_REPOSITORY=s3:http://192.168.1.132:3900/pxbackup
#   AWS_ACCESS_KEY_ID=<Garage key id>
#   AWS_SECRET_ACCESS_KEY=<Garage secret>
#   AWS_DEFAULT_REGION=garage
#   ENV
#   chmod 600 /etc/px-backup.env
#
# There is no RESTIC_PASSWORD on purpose: the repository key has an empty
# passphrase, so every restic call runs with --insecure-no-password and nobody
# has to keep a password alive.  The bucket is trusted (internal network only,
# backed up in its own right at the destination); whoever holds the Garage key
# above can therefore read every dump.  Encryption can be turned back on without
# re-uploading anything:
#
#   set -a; . /etc/px-backup.env; set +a
#   restic --insecure-no-password key add --new-password-file /path/to/pw
#   restic --insecure-no-password key remove <the empty-key id>
#
# ...then put RESTIC_PASSWORD back into /etc/px-backup.env and drop the flag
# from the two scripts that use it.
#
# The bucket and its key are created on the Garage node:
#
#   docker exec garage garage key create pxbackup
#   docker exec garage garage bucket create pxbackup
#   docker exec garage garage bucket allow pxbackup --read --write --key pxbackup
#
# and the repository itself is initialised once (never against an existing
# repository -- that would fail, and re-initialising destroys nothing but
# confusion):
#
#   set -a; . /etc/px-backup.env; set +a
#   restic init && restic backup --tag host /var/lib/secrets && restic check

set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" != "0" ]; then
  echo "run as root (installs into /usr/local/sbin and /etc/systemd/system)" >&2
  exit 1
fi

if ! command -v restic >/dev/null; then
  echo "installing restic ..."
  apt-get install -y restic
fi

if [ ! -r /etc/px-backup.env ]; then
  echo "ERROR: /etc/px-backup.env is missing; see the header of this script" >&2
  exit 1
fi
if ! grep -q '^RESTIC_REPOSITORY=s3:http://' /etc/px-backup.env; then
  echo "ERROR: RESTIC_REPOSITORY must be s3:http://<garage>:3900/pxbackup" >&2
  echo "       (restic >= 0.17 uses HTTPS unless the URL says otherwise," >&2
  echo "        and Garage serves plaintext HTTP on :3900)" >&2
  exit 1
fi
if grep -q '^RESTIC_PASSWORD=' /etc/px-backup.env; then
  echo "ERROR: /etc/px-backup.env still defines RESTIC_PASSWORD." >&2
  echo "       This repository is opened with an empty passphrase, and restic" >&2
  echo "       refuses --insecure-no-password when a password is also supplied." >&2
  exit 1
fi

# Prove the empty key really opens the repository before enabling the timer.
if ! ( set -a; . /etc/px-backup.env; set +a; unset RESTIC_PASSWORD
       restic --insecure-no-password cat config >/dev/null 2>&1 ); then
  echo "ERROR: the repository did not open with an empty password." >&2
  echo "       Add a key for it first:" >&2
  echo "       restic key add --new-insecure-no-password   (once, with the old password)" >&2
  exit 1
fi

install -m 700 -o root -g root "$SRC/px-s3-backup.sh" /usr/local/sbin/px-s3-backup.sh
install -m 644 -o root -g root "$SRC/systemd/px-s3-backup.service" /etc/systemd/system/px-s3-backup.service
install -m 644 -o root -g root "$SRC/systemd/px-s3-backup.timer" /etc/systemd/system/px-s3-backup.timer

systemctl daemon-reload
systemctl enable --now px-s3-backup.timer

echo "installed:"
systemctl --no-pager --no-legend list-timers px-s3-backup.timer
echo
echo "repository check:  set -a; . /etc/px-backup.env; set +a; restic cat config"
echo "first real run:    systemctl start px-s3-backup.service   (journalctl -f)"
