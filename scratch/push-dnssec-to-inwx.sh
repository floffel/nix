#!/usr/bin/env bash
# Push DNSSEC DS records to INWX registrar via DomRobot XML-RPC API.
# Required secrets file: /var/lib/secrets/nsd/inwx.env
#   INWX_USER=username
#   INWX_PASS=password
set -euo pipefail

SECRETS_FILE="/var/lib/secrets/nsd/inwx.env"
API_URL="https://api.domrobot.com/xmlrpc/"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "ERROR: $SECRETS_FILE not found — create it with INWX_USER and INWX_PASS" >&2
  exit 1
fi
source "$SECRETS_FILE"

inwx_call() {
  local method="$1" body="$2"
  curl -s -X POST "$API_URL" \
    -H "Content-Type: text/xml" \
    --data-binary '<?xml version="1.0"?>
<methodCall>
  <methodName>'"$method"'</methodName>
  <params>
    <param><value><struct>
      <member>
        <name>user</name><value><string>'"$INWX_USER"'</string></value>
      </member>
      <member>
        <name>pass</name><value><string>'"$INWX_PASS"'</string></value>
      </member>
      '"$body"'
    </struct></value></param>
  </params>
</methodCall>'
}

for zone in minnecker.com floffel.de sbminnecker.de substitution.art; do
  zonefile="/var/lib/nsd/zones/${zone}"
  [ -f "$zonefile" ] || continue

  echo "=== ${zone} ==="

  ds_records=$(nix-shell -p bind --run "dnssec-dsfromkey -2 -f '${zonefile}' '${zone}'" 2>/dev/null || true)
  if [ -z "$ds_records" ]; then
    echo "  WARNING: Could not generate DS records" >&2
    continue
  fi

  # Also get the KSK DNSKEY line for INWX API
  dnskey_line=$(grep "DNSKEY 257 " "$zonefile" 2>/dev/null | head -1 || true)
  if [ -z "$dnskey_line" ]; then
    echo "  WARNING: No KSK DNSKEY found" >&2
    continue
  fi

  echo "$ds_records" | while read -r _ _ _ keytag algo digest_type digest; do
    echo "  KeyTag=${keytag} Alg=${algo} Type=${digest_type} Digest=${digest}"

    body="
      <member>
        <name>domainname</name><value><string>${zone}</string></value>
      </member>
      <member>
        <name>dnskey</name><value><string>${dnskey_line}</string></value>
      </member>"

    result=$(inwx_call "dnssec.adddnskey" "$body")
    echo "  DEBUG: $(echo "$result" | tr '<>' '\n' | grep -E 'code|msg|reason' | tr -d '/')" >&2

    if echo "$result" | grep -q '<name>code</name><value><int>1000</int>'; then
      echo "  -> OK"
    else
      reason=$(echo "$result" | sed -n 's/.*<name>reason<\/name><value><string>\([^<]*\).*/\1/p' || true)
      echo "  -> FAILED: ${reason:-unknown}"
    fi
  done
  echo
done
