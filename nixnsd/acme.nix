# NixOS Service Configuration for ACME (Let's Encrypt) DNS-01 Challenge on NSD
{ config, pkgs, lib, ... }:

let
  # The real hook script that runs as root
  dnsHookReal = pkgs.writeScript "dns-hook-real.sh" ''
    #!/bin/sh
    ACTION=$1
    FQDN=$2
    VALUE=$3
    DOMAIN=$(echo "$FQDN" | sed -e 's/\.$//' -e 's/^_acme-challenge\.//')
    ZONE_FILE="/var/lib/nsd/zones/''${DOMAIN}"

    # Extract current serial and increment it to notify secondary nameservers
    CURRENT_SERIAL=$(grep -o -E '[0-9]+[[:space:]]*;[[:space:]]*serial' "$ZONE_FILE" | grep -o -E '[0-9]+')
    if [ -n "$CURRENT_SERIAL" ]; then
      NEW_SERIAL=$((CURRENT_SERIAL + 1))
      sed -i "s/''${CURRENT_SERIAL}\([[:space:]]*;[[:space:]]*serial\)/''${NEW_SERIAL}\1/" "$ZONE_FILE"
    fi

    if [ "$ACTION" = "present" ]; then
      # Append the TXT record to the zone file
      echo "_acme-challenge IN TXT \"$VALUE\"" >> "$ZONE_FILE"
      # Reload NSD to serve the challenge
      /run/current-system/sw/bin/systemctl reload nsd
      # Wait for Hetzner secondary DNS nameservers to sync via AXFR
      sleep 15
    elif [ "$ACTION" = "cleanup" ]; then
      # Remove the TXT record line
      sed -i "/_acme-challenge IN TXT/d" "$ZONE_FILE"
      # Reload NSD
      /run/current-system/sw/bin/systemctl reload nsd
    fi
  '';

  # The wrapper script that Lego calls, executing the real script as root via sudo
  dnsHookWrapper = pkgs.writeScript "dns-hook.sh" ''
    #!/bin/sh
    exec sudo ${dnsHookReal} "$@"
  '';
in
{
  # 1. Enable ACME configurations for wildcards
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "admin@minnecker.com";
      dnsProvider = "exec";
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
          chmod 600 /var/lib/secrets/ssl/minnecker.com/key.pem
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
          chmod 600 /var/lib/secrets/ssl/floffel.de/key.pem
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
          chmod 600 /var/lib/secrets/ssl/sbminnecker.de/key.pem
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
          chmod 600 /var/lib/secrets/ssl/substitution.art/key.pem
        '';
      };
    };
  };

  # 2. Allow acme user to run the real dns-hook script as root via sudo without password
  security.sudo = {
    enable = true;
    extraRules = [
      {
        users = [ "acme" ];
        commands = [
          {
            command = "${dnsHookReal}";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
