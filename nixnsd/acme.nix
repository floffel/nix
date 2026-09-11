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
    DOMAIN=$(echo "$FQDN" | sed -e 's/\.$//' -e 's/^_acme-challenge\.//')
    ZONE_FILE="/var/lib/nsd/zones/''${DOMAIN}"
    KEYDIR="/var/lib/nsd/dnssec"

    # Bump the SOA serial and re-sign the modified zone. The zones are
    # DNSSEC-signed, so an appended challenge record must be signed to keep
    # the zone valid, and the serial must change or the AXFR secondaries
    # (Hetzner) discard the transfer and the challenge never goes public.
    resign_zone() {
      SERIAL=$(awk '/[[:space:]]IN[[:space:]]+SOA[[:space:]]/ { print $7; exit }' "$ZONE_FILE")
      if ! [ "$SERIAL" -gt 0 ] 2>/dev/null; then
        SERIAL=$(date +%Y%m%d)00
      fi
      NEW_SERIAL=$((SERIAL + 1))
      dnssec-signzone -S -K "$KEYDIR" -o "$DOMAIN" -O full -N "$NEW_SERIAL" "$ZONE_FILE" || {
        echo "dns-hook: dnssec-signzone failed for $DOMAIN" >&2
        exit 1
      }
      mv -f "$ZONE_FILE.signed" "$ZONE_FILE"
      # Reload NSD to serve the challenge
      /run/current-system/sw/bin/systemctl reload nsd
    }

    if [ "$ACTION" = "present" ]; then
      # Append the TXT record to the zone file
      echo "_acme-challenge IN TXT \"$VALUE\"" >> "$ZONE_FILE"
      resign_zone
      # Wait for Hetzner secondary DNS nameservers to sync via AXFR
      sleep 120
    elif [ "$ACTION" = "cleanup" ]; then
      # Remove the TXT record line
      sed -i "/_acme-challenge IN TXT/d" "$ZONE_FILE"
      resign_zone
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
