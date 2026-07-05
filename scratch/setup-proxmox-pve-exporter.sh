#!/usr/bin/env bash
# setup-proxmox-pve-exporter.sh — install prometheus-pve-exporter on the
# Proxmox host so the nixmonitoring Prometheus can scrape hypervisor-accurate
# per-guest (LXC/QEMU) AND per-node resource metrics.
#
# Unlike node_exporter (which inside an unprivileged LXC reports host-level
# CPU/memory and is therefore misleading for "per container" views), the
# pve_exporter queries the PVE API and exposes the hypervisor's cgroup-based
# per-guest accounting:
#   pve_cpu_usage_ratio{id="lxc/101"}        # 0..1 per guest
#   pve_memory_usage_bytes / pve_memory_size_bytes
#   pve_network_receive_bytes_total / pve_network_transmit_bytes_total
#   pve_disk_usage_bytes / pve_disk_size_bytes
#   pve_up / pve_uptime_seconds / pve_guest_info{id,node,name,type,tags}
#
# Run this ONCE on the Proxmox host as root:
#   bash setup-proxmox-pve-exporter.sh
#
# The exporter listens on :9221. nixmonitoring's Prometheus already has
# "proxmox:9221" in its scrape targets (resolves via the hosts.nix entry).
#
# What this script does:
#   1. pip-installs prometheus-pve-exporter into a venv (Debian ships an old
#      version; a venv keeps it isolated and current).
#   2. Creates a dedicated API-token role `monitoring@pve` (read-only, no
#      realm-admin) so the exporter never holds the root@pam password.
#   3. Writes /etc/prometheus/pve.yml with the token and verify_ssl=false
#      (self-signed PVE cert by default; set verify_ssl=true if you use a
#      real cert and copy the CA into the exporter's trust store).
#   4. Installs a systemd unit and starts it.

set -euo pipefail

VENV=/opt/pve-exporter
TOKEN_USER="monitoring@pve"
TOKEN_NAME="prometheus"
CONF=/etc/prometheus/pve.yml

echo "=== 1/4  Install prometheus-pve-exporter into a venv ==="
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip >/dev/null
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet prometheus-pve-exporter

echo "=== 2/4  Create API token role $TOKEN_USER (read-only) ==="
# Create a dedicated PVE user for monitoring (does nothing if it exists).
pveum user add "$TOKEN_USER" 2>/dev/null || true
# Grant the role read-only access on the / path (all resources).
# PVERoleUser already exists as the read-only role. Assign it to the user.
pveum acl modify / -user "$TOKEN_USER" -role PVEAuditor 2>/dev/null \
  || pveum acl add / -user "$TOKEN_USER" -role PVEAuditor 2>/dev/null || true
# Generate an API token under the user. pveum token add prints the secret once.
TOKEN_OUT=$(pveum user token add "$TOKEN_USER" "$TOKEN_NAME" --privsep 0 2>&1) || true
# If the token already existed we can't read the secret again; re-add it.
if ! printf '%s' "$TOKEN_OUT" | grep -q 'value'; then
  pveum user token remove "$TOKEN_USER" "$TOKEN_NAME" 2>/dev/null || true
  TOKEN_OUT=$(pveum user token add "$TOKEN_USER" "$TOKEN_NAME" --privsep 0 2>&1)
fi
TOKEN_VALUE=$(printf '%s' "$TOKEN_OUT" | sed -n 's/^.*value:[[:space:]]*//p' | head -1)
[ -n "$TOKEN_VALUE" ] || { echo "Failed to obtain API token value:"; echo "$TOKEN_OUT"; exit 1; }

echo "=== 3/4  Write $CONF ==="
install -d -m 0750 -o root -g root "$(dirname "$CONF")"
cat > "$CONF" <<EOF
default:
  user: $TOKEN_USER
  token_name: $TOKEN_NAME
  token_value: $TOKEN_VALUE
  verify_ssl: false
EOF
chmod 600 "$CONF"

echo "=== 4/4  Install + start systemd service ==="
cat > /etc/systemd/system/pve-exporter.service <<'UNIT'
[Unit]
Description=Prometheus PVE Exporter
After=network.target

[Service]
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file /etc/prometheus/pve.yml --web.listen-address=:9221
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pve-exporter

echo
echo "Done. pve_exporter is running on :9221."
echo "Verify:  curl -s http://localhost:9221/pve | grep pve_cpu_usage_ratio"
echo
echo "The nixmonitoring Prometheus already scrapes 'proxmox:9221'."
echo "If metrics don't appear, ensure the Proxmox host firewall allows"
echo "inbound TCP 9221 from the container subnet (10.20.20.0/24)."
