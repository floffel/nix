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

# Extract all keyTag values from a dnssec.listkeys response. The API returns
# <name>keyTag</name><value><string>30646</string></value>, not the lowercase
# integer form used by older DomRobot documentation. INWX also leaves a
# DELAYED placeholder entry with keyTag 0 after a failed submission; ignore it.
keytags() {
  grep -oE '<name>keyTag</name><value><(string|int)>[0-9]+' | grep -oE '[0-9]+$' | grep -v '^0$' || true
}

# sbminni.de is intentionally not in this list: it is not registered in the
# INWX account (adddnskey: "domain does not seem to exist"). It is signed and
# served by nsd, but its DS must be added at whichever registrar it is
# registered with when the delegation is switched to px.
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

  current=$(inwx_call "dnssec.listkeys" \
    "<member><name>domainname</name><value><string>${zone}</string></value></member>")

  if [ "$(echo "$current" | api_code)" != "1000" ]; then
    # Not every signed zone has to be registered at INWX (e.g. a domain at
    # another registrar). Skip it; the external DNSSEC checks will still
    # catch a genuinely missing DS for zones that are supposed to be here.
    echo "  WARNING: dnssec.listkeys failed for ${zone}: $(echo "$current" | api_msg) — skipping (not an INWX zone?)" >&2
    continue
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
  #    KSK is confirmed present above. The current INWX API exposes
  #    dnssec.adddnskey but no removal method, so warn instead of failing the
  #    whole run (otherwise the hourly nsd-dnssec unit fails forever).
  while read -r stale; do
    [ -n "$stale" ] || continue
    [ "$stale" = "$keytag" ] && continue
    echo "  WARNING: stale keytag ${stale} still registered at INWX; remove it manually (the current API has no removednskey method)" >&2
  done <<< "$present"

  echo
done