#!/usr/bin/env bash
set -euo pipefail

echo "=== Zone DNSKEY + DS Records ==="
echo

for zone in minnecker.com floffel.de sbminnecker.de substitution.art; do
  echo "--- ${zone} ---"

  # Get DNSKEY from NSD directly — most reliable
  echo "  DNSKEY (from NSD):"
  dig DNSKEY "${zone}" @10.20.20.11 +short | while read -r key; do
    echo "    ${key}"
  done

  # Get DS records from NSD if zone publishes CDS/CDNSKEY
  echo "  DS (from NSD):"
  dig DS "${zone}" @10.20.20.11 +short | while read -r ds; do
    echo "    ${ds}"
  done

  # If no DS published by NSD, generate from DNSKEY
  if ! dig DS "${zone}" @10.20.20.11 +short | grep -q .; then
    echo "  DS (generated from DNSKEY — for registrar):"

    # Extract DNSKEY, write to temp file, generate DS
    tmpfile=$(mktemp)
    dig DNSKEY "${zone}" @10.20.20.11 +noall +answer | \
      while read -r _ _ _ key; do
        echo "${zone}. IN DNSKEY ${key}" >> "$tmpfile"
      done

    if [ -s "$tmpfile" ]; then
      dnssec-dsfromkey -2 "$tmpfile" | column -t
    fi
    rm -f "$tmpfile"
  fi

  echo
done
