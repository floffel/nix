#!/usr/bin/env bash
set -euo pipefail

SECRETS_FILE="/var/lib/secrets/nsd/inwx.env"
API_URL="https://api.domrobot.com/xmlrpc/"
KEYDIR="/var/lib/nsd/dnssec"

[ -f "$SECRETS_FILE" ] || { echo "ERROR: $SECRETS_FILE not found" >&2; exit 1; }
# shellcheck disable=SC1090
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

# Extract the DomRobot API result code from a response (1000 = success).
api_code() {
  sed -n 's/.*<name>code<\/name><value><int>\([0-9]*\)<\/int>.*/\1/p' | head -1
}

api_msg() {
  sed -n 's/.*<name>msg<\/name><value><string>\([^<]*\).*/\1/p' | head -1
}

# Extract all <int> keytag values from a dnssec.list response.
keytags() {
  grep -oE '<name>keytag</name><value><int>[0-9]+' | grep -oE '[0-9]+$' || true
}

for zone in minnecker.com floffel.de sbminnecker.de substitution.art; do
  echo "=== ${zone} ==="

  ksk_file=""
  for f in "$KEYDIR"/K"${zone}".+013+*.key; do
    [ -f "$f" ] || continue
    if head -1 "$f" | grep -q "key-signing key" 2>/dev/null; then
      ksk_file="$f"
      break
    fi
  done

  if [ -z "$ksk_file" ]; then
    echo "  WARNING: No KSK key file found" >&2
    continue
  fi

  keytag=$(basename "$ksk_file" | sed -E 's/^K.*\+([0-9]+)\.key$/\1/')
  keytag=$((10#$keytag))

  dnskey_line=$(grep -v "^;" "$ksk_file" | head -1)
  # Send only the RDATA (flags protocol algorithm base64) to DomRobot; the
  # API wants the bare DNSKEY record data, not the full zonefile line.
  dnskey_rdata=$(echo "$dnskey_line" | sed -E 's/^.*[[:space:]]DNSKEY[[:space:]]+//')
  ds_line=$(dnssec-dsfromkey -2 "$ksk_file" | awk '{print $5, $6, $7, $8, $9}')

  echo "  KeyFile: $(basename "$ksk_file") (keytag ${keytag})"
  echo "  DNSKEY: ${dnskey_rdata}"
  echo "  DS:     ${ds_line}"

  current=$(inwx_call "dnssec.list" \
    "<member><name>domainname</name><value><string>${zone}</string></value></member>")

  if [ "$(echo "$current" | api_code)" != "1000" ]; then
    echo "  FAILED: dnssec.list: $(echo "$current" | api_msg)" >&2
    exit 1
  fi

  present=$(echo "$current" | keytags)
  echo "  Keytags registered at INWX: ${present:-none}"

  # 1) Make sure the CURRENT KSK is registered.
  if ! echo "$present" | grep -qx "$keytag"; then
    echo "  Adding DNSKEY for keytag ${keytag}..."
    result=$(inwx_call "dnssec.adddnskey" "
      <member><name>domainname</name><value><string>${zone}</string></value></member>
      <member><name>dnskey</name><value><string>${dnskey_rdata}</string></value></member>")
    if [ "$(echo "$result" | api_code)" != "1000" ]; then
      echo "  FAILED: dnssec.adddnskey: $(echo "$result" | api_msg)" >&2
      echo "  Add this DS manually at INWX (DNSSEC tab): ${zone}. ${ds_line}" >&2
      exit 1
    fi
    echo "  -> added"
  else
    echo "  -> keytag ${keytag} already registered"
  fi

  # 2) Remove stale keytags (rotated-out KSKs). Only safe once the current
  #    KSK is confirmed present above.
  while read -r stale; do
    [ -n "$stale" ] || continue
    [ "$stale" = "$keytag" ] && continue
    echo "  Removing stale keytag ${stale}..."
    result=$(inwx_call "dnssec.removednskey" "
      <member><name>domainname</name><value><string>${zone}</string></value></member>
      <member><name>keytag</name><value><int>${stale}</int></value></member>")
    if [ "$(echo "$result" | api_code)" != "1000" ]; then
      echo "  FAILED: dnssec.removednskey (keytag ${stale}): $(echo "$result" | api_msg)" >&2
      echo "  Remove keytag ${stale} manually at INWX (DNSSEC tab)" >&2
      exit 1
    fi
    echo "  -> removed"
  done <<< "$present"

  echo
done