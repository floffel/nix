#!/usr/bin/env bash
set -euo pipefail

SECRETS_FILE="/var/lib/secrets/nsd/inwx.env"
API_URL="https://api.domrobot.com/xmlrpc/"
KEYDIR="/var/lib/nsd/dnssec"

[ -f "$SECRETS_FILE" ] || { echo "ERROR: $SECRETS_FILE not found" >&2; exit 1; }
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
      <member><name>user</name><value><string>'"$INWX_USER"'</string></value></member>
      <member><name>pass</name><value><string>'"$INWX_PASS"'</string></value></member>
      '"$body"'
    </struct></value></param>
  </params>
</methodCall>'
}

for zone in minnecker.com floffel.de sbminnecker.de substitution.art; do
  echo "=== ${zone} ==="

  ksk_file=""
  for f in "$KEYDIR"/K"${zone}".+013+*.key; do
    [ -f "$f" ] || continue
    if grep -qE "DNSKEY\s+257\s" "$f" 2>/dev/null; then
      ksk_file="$f"
      break
    fi
  done

  if [ -z "$ksk_file" ]; then
    echo "  WARNING: No KSK key file found" >&2
    continue
  fi

  dnskey_line=$(head -1 "$ksk_file")
  echo "  KeyFile: $(basename "$ksk_file")"
  echo "  DNSKEY: ${dnskey_line}"

  body="
    <member><name>domainname</name><value><string>${zone}</string></value></member>
    <member><name>dnskey</name><value><string>${dnskey_line}</string></value></member>"

  result=$(inwx_call "dnssec.adddnskey" "$body")

  if echo "$result" | grep -q '<name>code</name><value><int>1000</int>'; then
    echo "  -> OK"
  else
    msg=$(echo "$result" | sed -n 's/.*<name>msg<\/name><value><string>\([^<]*\).*/\1/p' || true)
    echo "  -> FAILED: ${msg:-unknown}"
  fi
  echo
done
