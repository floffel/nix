#!/usr/bin/env bash
# setup-proxmox-metric-server.sh — configure Proxmox VE's built-in External
# Metric Server to push hypervisor metrics to the InfluxDB v2 running on the
# nixmonitoring container.
#
# This uses ONLY Proxmox's built-in feature (Datacenter → Metric Server) — no
# third-party exporters, no API tokens, no venvs on the Proxmox host. Proxmox
# pushes per-node and per-guest (LXC/QEMU) resource metrics via its HTTP v2 API.
#
# Run on the Proxmox host as root:
#   bash setup-proxmox-metric-server.sh
#
# Prerequisites:
#   - The nixmonitoring container must be running with InfluxDB v2 on :8086
#   - The InfluxDB init oneshot must have completed (token file exists)
#   - The Proxmox host must be able to resolve "nixmonitoring" (add to /etc/hosts
#     if needed: echo "10.20.20.23 nixmonitoring" >> /etc/hosts)

set -euo pipefail

INFLUX_HOST="nixmonitoring"
INFLUX_PORT="8086"
INFLUX_ORG="minnecker"
INFLUX_BUCKET="proxmox"
METRIC_SERVER_ID="influxdb-minnecker"
TOKEN_FILE="/var/lib/secrets/influxdb/token"  # on nixmonitoring, not here

echo "=== Proxmox External Metric Server Setup ==="
echo
echo "This script configures Proxmox's built-in metric server to push"
echo "hypervisor metrics to InfluxDB v2 on ${INFLUX_HOST}:${INFLUX_PORT}."
echo

# --- 1. Obtain the InfluxDB token ---
echo "1/3  Obtain InfluxDB token"
echo
echo "The InfluxDB token is stored on the nixmonitoring container at:"
echo "  ${TOKEN_FILE}"
echo
echo "Read it there and paste it below (or press Enter to skip if already"
echo "configured):"
echo
read -rp "InfluxDB token: " INFLUX_TOKEN
if [ -z "$INFLUX_TOKEN" ]; then
  echo "No token provided. Aborting."
  echo
  echo "To get the token, run on the nixmonitoring container:"
  echo "  cat ${TOKEN_FILE}"
  exit 1
fi

# --- 2. Verify connectivity ---
echo
echo "2/3  Verify InfluxDB is reachable"
if ! curl -sf "http://${INFLUX_HOST}:${INFLUX_PORT}/health" >/dev/null 2>&1; then
  echo "WARNING: Cannot reach InfluxDB at http://${INFLUX_HOST}:${INFLUX_PORT}/health"
  echo "Ensure the Proxmox host can resolve and reach nixmonitoring."
  echo "Add to /etc/hosts if needed: echo '10.20.20.23 nixmonitoring' >> /etc/hosts"
  exit 1
fi
echo "  InfluxDB is reachable."

# Verify the token works
if ! curl -sf -H "Authorization: Token ${INFLUX_TOKEN}" \
     "http://${INFLUX_HOST}:${INFLUX_PORT}/api/v2/buckets?name=${INFLUX_BUCKET}" >/dev/null 2>&1; then
  echo "ERROR: Token is invalid or bucket '${INFLUX_BUCKET}' does not exist."
  echo "Verify the token on the nixmonitoring container:"
  echo "  curl -H 'Authorization: Token \$(cat ${TOKEN_FILE})' \\"
  echo "    http://localhost:8086/api/v2/buckets?name=${INFLUX_BUCKET}"
  exit 1
fi
echo "  Token is valid, bucket '${INFLUX_BUCKET}' exists."

# --- 3. Configure the metric server in Proxmox ---
echo
echo "3/3  Configure Proxmox External Metric Server"

# Remove existing entry if it exists (idempotent).
pvesh delete "/cluster/metricserver/${METRIC_SERVER_ID}" 2>/dev/null || true

# Create the metric server entry. Proxmox pushes via HTTP v2 API.
pvesh create /cluster/metricserver/${METRIC_SERVER_ID} \
  -type influxdb \
  -server "${INFLUX_HOST}" \
  -port "${INFLUX_PORT}" \
  -organization "${INFLUX_ORG}" \
  -bucket "${INFLUX_BUCKET}" \
  -token "${INFLUX_TOKEN}" \
  -influxdbproto http \
  -timeout 2 \
  -max-body-size 25000000

echo
echo "Done. Proxmox will now push metrics to InfluxDB every ~10 seconds."
echo
echo "Verify in the Proxmox web UI: Datacenter → Metric Server"
echo "Or check:  pvesh get /cluster/metricserver/${METRIC_SERVER_ID}"
echo
echo "Verify data in InfluxDB (on nixmonitoring):"
echo "  curl -H 'Authorization: Token \$(cat ${TOKEN_FILE})' \\"
echo "    'http://localhost:8086/api/v2/query?org=${INFLUX_ORG}' \\"
echo "    -H 'Content-type: application/vnd.flux' \\"
echo "    -d 'from(bucket:\"${INFLUX_BUCKET}\") |> range(start:-1m) |> limit(n:5)'"
