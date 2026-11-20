# NixOS Service Configuration for ACME (Let's Encrypt) DNS-01 Challenge on NSD
{ config, pkgs, lib, ... }:

let
  # The real hook script that runs as root
  dnsHookReal = pkgs.writeScript "dns-hook-real.sh" ''
    #!/bin/sh
    export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH
    ACTION=$1
    FQDN=$2
    VALUE=$3
    ZONESDIR=/var/lib/nsd/zones
    KEYDIR="/var/lib/nsd/dnssec"

    # The owner name lego wants the TXT for, fully qualified. lego hands us the
    # CNAME target whenever it followed a CNAME, so this is either
    # _acme-challenge.<zone> or, after a wildcard-synthesized CNAME, a plain
    # host name that only exists as a record inside the parent zone.
    NAME=$(echo "$FQDN" | sed -e 's/\.$//')

    # Find the zone that actually serves NAME by walking up the label chain:
    # _acme-challenge.minnecker.com -> minnecker.com, and the CNAME target
    # px.minnecker.com -> minnecker.com too, because px is not a zone of its
    # own. A file only counts as a zone when it is non-empty and carries an
    # SOA, so a stale or emptied leftover can never be signed again.
    ZONE=""
    CAND="$NAME"
    while [ -n "$CAND" ]; do
      if [ -s "$ZONESDIR/$CAND" ] && grep -qE 'IN[[:space:]]+SOA' "$ZONESDIR/$CAND"; then
        ZONE="$CAND"
        ZONE_FILE="$ZONESDIR/$CAND"
        break
      fi
      CAND=''${CAND#*.}
    done
    if [ -z "$ZONE" ]; then
      echo "dns-hook: no served zone for $NAME, refusing to modify anything" >&2
      exit 1
    fi

    # Bump the SOA serial and re-sign the modified zone. The zones are
    # DNSSEC-signed, so an appended challenge record must be signed to keep
    # the zone valid, and the serial must change or the AXFR secondaries
    # (Hetzner) discard the transfer and the challenge never goes public.
    resign_zone() {
      # Operate on a work copy so a signing failure never leaves the live
      # zone modified or half-signed.
      WORK="''${ZONE_FILE}.acme-work"
      cp -f "$ZONE_FILE" "$WORK"
      SERIAL=$(awk '/[[:space:]]IN[[:space:]]+SOA[[:space:]]/ { print $7; exit }' "$WORK")
      if ! [ "$SERIAL" -gt 0 ] 2>/dev/null; then
        SERIAL=$(date +%Y%m%d)00
      fi
      NEW_SERIAL=$((SERIAL + 1))
      # Bump the SOA serial in the work copy: AXFR secondaries discard
      # transfers whose serial is unchanged.
      sed -i "/^[^;]*[[:space:]]IN[[:space:]]\+SOA[[:space:]]/s/[0-9]\{10\}/$NEW_SERIAL/" "$WORK"
      # Re-sign the zone. signzone keeps the in-file serial (explicit -N
      # numbers are rejected by this BIND build), so only the bump above
      # matters.
      dnssec-signzone -S -K "$KEYDIR" -o "$ZONE" -O full "$WORK" || {
        rm -f "$WORK" "$WORK.signed"
        echo "dns-hook: dnssec-signzone failed for $ZONE" >&2
        exit 1
      }
      # A short-lived challenge record must never be able to take
      # authoritative DNS down, so only signed output that verifies may
      # replace the live zone. Same two gates nsd-dnssec applies.
      dnssec-verify -o "$ZONE" "$WORK.signed" || {
        rm -f "$WORK" "$WORK.signed"
        echo "dns-hook: dnssec-verify failed for $ZONE, live zone untouched" >&2
        exit 1
      }
      nsd-checkzone "$ZONE" "$WORK.signed" || {
        rm -f "$WORK" "$WORK.signed"
        echo "dns-hook: nsd-checkzone failed for $ZONE, live zone untouched" >&2
        exit 1
      }
      mv -f "$WORK.signed" "$ZONE_FILE"
      rm -f "$WORK"
      # Reload NSD to serve the challenge
      /run/current-system/sw/bin/systemctl reload nsd
    }

    if [ "$ACTION" = "present" ]; then
      # Append the TXT record for exactly the name lego asked about.
      printf '%s\t300 IN TXT\t"%s"\n' "$NAME." "$VALUE" >> "$ZONE_FILE"
      resign_zone
      # Wait for Hetzner secondary DNS nameservers to sync via AXFR
      sleep 120
    elif [ "$ACTION" = "cleanup" ]; then
      # Delete only the line carrying this challenge value. The owner name can
      # hold other records (px.minnecker.com has A and AAAA), so never match
      # on the name alone.
      LINE=$(grep -n "IN TXT.*\"$VALUE\"" "$ZONE_FILE" | tail -1 | cut -d: -f1)
      if [ -n "$LINE" ]; then
        sed -i "''${LINE}d" "$ZONE_FILE"
        resign_zone
      fi
      # Wait a bit before returning to ensure Let's Encrypt secondary validation is fully complete
      sleep 30
    fi
  '';

  # The wrapper script that Lego calls, executing the real script as root via sudo
  # The wrapper script that Lego calls, executing the real script directly
  dnsHookWrapper = pkgs.writeScript "dns-hook.sh" ''
    #!/bin/sh
    export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH
    exec ${dnsHookReal} "$@"
  '';
in
{
  # 1. Enable ACME configurations for wildcards
  security.acme = {
    acceptTerms = true;
    useRoot = true; # Run ACME service as root to bypass NoNewPrivileges sudo limitation in container
    defaults = {
      email = "admin@minnecker.com";
      dnsProvider = "exec";
      dnsPropagationCheck = false;
      environmentFile = pkgs.writeText "acme-env" ''
        EXEC_PATH=${dnsHookWrapper}
      '';
    };
    certs = {
      "minnecker.com" = {
        domain = "minnecker.com";
        extraDomainNames = [ "*.minnecker.com" ];
        postRun = ''
          mkdir -p /var/lib/secrets/ssl/minnecker.com
          cp fullchain.pem /var/lib/secrets/ssl/minnecker.com/fullchain.pem
          cp key.pem /var/lib/secrets/ssl/minnecker.com/key.pem
          chmod 644 /var/lib/secrets/ssl/minnecker.com/fullchain.pem
          chmod 644 /var/lib/secrets/ssl/minnecker.com/key.pem
        '';
      };
      "floffel.de" = {
        domain = "floffel.de";
        extraDomainNames = [ "*.floffel.de" ];
        postRun = ''
          mkdir -p /var/lib/secrets/ssl/floffel.de
          cp fullchain.pem /var/lib/secrets/ssl/floffel.de/fullchain.pem
          cp key.pem /var/lib/secrets/ssl/floffel.de/key.pem
          chmod 644 /var/lib/secrets/ssl/floffel.de/fullchain.pem
          chmod 644 /var/lib/secrets/ssl/floffel.de/key.pem
        '';
      };
      "sbminnecker.de" = {
        domain = "sbminnecker.de";
        extraDomainNames = [ "*.sbminnecker.de" ];
        postRun = ''
          mkdir -p /var/lib/secrets/ssl/sbminnecker.de
          cp fullchain.pem /var/lib/secrets/ssl/sbminnecker.de/fullchain.pem
          cp key.pem /var/lib/secrets/ssl/sbminnecker.de/key.pem
          chmod 644 /var/lib/secrets/ssl/sbminnecker.de/fullchain.pem
          chmod 644 /var/lib/secrets/ssl/sbminnecker.de/key.pem
        '';
      };
      "substitution.art" = {
        domain = "substitution.art";
        extraDomainNames = [ "*.substitution.art" ];
        postRun = ''
          mkdir -p /var/lib/secrets/ssl/substitution.art
          cp fullchain.pem /var/lib/secrets/ssl/substitution.art/fullchain.pem
          cp key.pem /var/lib/secrets/ssl/substitution.art/key.pem
          chmod 644 /var/lib/secrets/ssl/substitution.art/fullchain.pem
          chmod 644 /var/lib/secrets/ssl/substitution.art/key.pem
        '';
      };
    };
  };

  # 2. Add ReadWritePaths and CapabilityBoundingSet overrides for all ACME services
  systemd.services = let
    domains = [ "minnecker.com" "floffel.de" "sbminnecker.de" "substitution.art" ];
    servicesForDomain = domain: [
      {
        name = "acme-${domain}";
        value.serviceConfig = {
          ReadWritePaths = [ "/var/lib/secrets/ssl" "/var/lib/nsd/zones" "/var/lib/nsd/dnssec" ];
          CapabilityBoundingSet = [ "CAP_DAC_OVERRIDE" "CAP_KILL" ];
        };
      }
      {
        name = "acme-order-renew-${domain}";
        value.serviceConfig = {
          ReadWritePaths = [ "/var/lib/secrets/ssl" "/var/lib/nsd/zones" "/var/lib/nsd/dnssec" ];
          CapabilityBoundingSet = [ "CAP_DAC_OVERRIDE" "CAP_KILL" ];
        };
      }
    ];
  in builtins.listToAttrs (builtins.concatMap servicesForDomain domains);
}
