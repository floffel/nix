#!/bin/bash
#
# Install/refresh the nightly host-secrets backup on the Proxmox host.
# Run from the repository checkout, on the host, as root:
#
#   install -m 700 scratch/backup-host-secrets.sh /usr/local/sbin/
#   ... or simply:  scratch/install-host-secrets-backup.sh
#
# Needs /etc/px-backup.env on the host (the repository coordinates of the
# Garage bucket that holds the off-host copy); see install-px-s3-backup.sh.
#
# Idempotent: safe to re-run after every change to the script or the units.

set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" != "0" ]; then
  echo "run as root (installs into /usr/local/sbin and /etc/systemd/system)" >&2
  exit 1
fi

install -m 700 -o root -g root "$SRC/backup-host-secrets.sh" /usr/local/sbin/backup-host-secrets.sh
install -m 644 -o root -g root "$SRC/systemd/host-secrets-backup.service" /etc/systemd/system/host-secrets-backup.service
install -m 644 -o root -g root "$SRC/systemd/host-secrets-backup.timer" /etc/systemd/system/host-secrets-backup.timer

systemctl daemon-reload
systemctl enable --now host-secrets-backup.timer

echo "installed:"
systemctl --no-pager --no-legend list-timers host-secrets-backup.timer
echo
echo "run one backup now with: systemctl start host-secrets-backup.service"
