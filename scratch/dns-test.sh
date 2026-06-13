#!/usr/bin/env bash
# Script to test and time DNS zone transfer propagation to secondary nameservers

ZONE_FILE="/var/lib/nsd/zones/floffel.de"

if [ ! -f "$ZONE_FILE" ]; then
  echo "Error: Zone file not found at $ZONE_FILE"
  exit 1
fi

CURRENT_SERIAL=$(grep -o -E '[0-9]+[[:space:]]*;[[:space:]]*serial' "$ZONE_FILE" | grep -o -E '[0-9]+')
if [ -z "$CURRENT_SERIAL" ]; then
  echo "Error: Could not parse serial from $ZONE_FILE"
  exit 1
fi

NEW_SERIAL=$((CURRENT_SERIAL + 1))

# Backup zone file
cp "$ZONE_FILE" "${ZONE_FILE}.bak"

# Make writable and append test record
chmod u+w "$ZONE_FILE"
echo "manualtest IN TXT \"test-at-$(date +%s)\"" >> "$ZONE_FILE"
sed -i "s/${CURRENT_SERIAL}\([[:space:]]*;[[:space:]]*serial\)/${NEW_SERIAL}\1/" "$ZONE_FILE"

# Reload NSD
pkill -HUP nsd
START_TIME=$(date +%s)
echo "NSD reloaded with serial $NEW_SERIAL at $(date)"
echo "Polling secondary nameservers for updates (checking every 5 seconds)..."

# Poll secondary nameservers
for ns in 213.239.242.238 213.133.100.103 193.47.99.3 78.47.124.81; do
  echo "Checking Nameserver: $ns"
  for i in {1..30}; do
    SERIAL=$(dig @$ns floffel.de SOA +short | grep -o -E '[0-9]+' | head -n 1)
    if [ "$SERIAL" = "$NEW_SERIAL" ]; then
      ELAPSED=$(( $(date +%s) - START_TIME ))
      echo "  [+] $ns synced successfully to serial $NEW_SERIAL in $ELAPSED seconds!"
      break
    fi
    sleep 5
  done
done

# Cleanup
mv "${ZONE_FILE}.bak" "$ZONE_FILE"
CLEANUP_SERIAL=$((NEW_SERIAL + 1))
sed -i "s/${NEW_SERIAL}\([[:space:]]*;[[:space:]]*serial\)/${CLEANUP_SERIAL}\1/" "$ZONE_FILE"
pkill -HUP nsd
echo "Cleaned up test records. NSD reloaded with serial $CLEANUP_SERIAL."
