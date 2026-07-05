#!/usr/bin/env bash
# setup-proxmox-node-exporter.sh — install Prometheus node_exporter on the
# Proxmox host so the nixmonitoring Prometheus can scrape host-level metrics
# (CPU, memory, disk, network, temps).  The Proxmox host is Debian-based and
# cannot run NixOS modules, so we deploy the static binary + a systemd unit.
#
# Run this ONCE on the Proxmox host as root:
#   bash setup-proxmox-node-exporter.sh
#
# The exporter listens on :9100 (same as the container node_exporters).
# nixmonitoring's Prometheus already has "proxmox:9100" in its scrape targets
# (resolves via the hosts.nix entry added to all containers).

set -euo pipefail

VERSION="1.8.2"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${ARCH}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading node_exporter v${VERSION} (${ARCH})..."
curl -fsSL "$URL" | tar xz -C "$TMP" --strip-components=1

install -m 0755 "$TMP/node_exporter" /usr/local/bin/node_exporter

cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now node_exporter

echo
echo "node_exporter is running on :9100."
echo "Verify:  curl -s http://localhost:9100/metrics | head"
echo
echo "The nixmonitoring Prometheus already scrapes 'proxmox:9100'."
echo "If metrics don't appear, ensure the Proxmox host firewall allows"
echo "inbound TCP 9100 from the container subnet (10.20.20.0/24)."
