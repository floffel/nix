#!/usr/bin/env bash
# Push DNSSEC DS records to INWX registrar via DomRobot XML-RPC API.
# Required secrets file: /var/lib/secrets/nsd/inwx.env
#   INWX_USER=username
#   INWX_PASS=password
set -euo pipefail

SECRETS_FILE="/var/lib/secrets/nsd/inwx.env"
API_URL="https://api.domrobot.com/xmlrpc/"
ZONES_FILE="/var/lib/nsd/zones"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "ERROR: $SECRETS_FILE not found — create it with INWX_USER and INWX_PASS" >&2
  exit 1
fi
source "$SECRETS_FILE"

# INWX XML-RPC helper
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
  zonefile="${ZONES_FILE}/${zone}"
  [ -f "$zonefile" ] || continue

  echo "=== ${zone} ==="

  # Get DNSKEY records from the signed zone file
  tmpfile=$(mktemp)
  dnskeys=$(grep -E "^${zone/./\\.}\.[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+DNSKEY[[:space:]]+" "$zonefile" 2>/dev/null || true)

  if [ -z "$dnskeys" ]; then
    echo "  WARNING: No DNSKEY records found in signed zone file" >&2
    rm -f "$tmpfile"
    continue
  fi

  echo "$dnskeys" > "$tmpfile"
  ds_records=$(dnssec-dsfromkey -2 "$tmpfile" 2>/dev/null || true)
  rm -f "$tmpfile"

  if [ -z "$ds_records" ]; then
    echo "  WARNING: Could not generate DS records from DNSKEY" >&2
    continue
  fi

  # Parse DS records and push each
  echo "$ds_records" | while read -r _ _ _ _ keytag algo digest_type digest; do
    echo "  KeyTag=${keytag} Alg=${algo} Type=${digest_type} Digest=${digest}"

    body="
      <member>
        <name>domain</name><value><string>${zone}</string></value>
      </member>
      <member>
        <name>keytag</name><value><int>${keytag}</int></value>
      </member>
      <member>
        <name>algorithm</name><value><int>${algo}</int></value>
      </member>
      <member>
        <name>dsType</name><value><int>${digest_type}</int></value>
      </member>
      <member>
        <name>digest</name><value><string>${digest}</string></value>
      </member>"

    result=$(inwx_call "domain.pushDnsSec" "$body")

    if echo "$result" | grep -q '<name>code</name><value><int>1000</int>'; then
      echo "  -> OK (pushed to registry)"
    else
      msg=$(echo "$result" | grep -oP '<name>msg</name><value><string>\K[^<]+' || echo "unknown error")
      echo "  -> FAILED: ${msg}"
    fi
  done
  echo
done
