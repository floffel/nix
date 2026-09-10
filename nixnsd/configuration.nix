# NixOS Server Configuration for the NSD Nameserver Container (nixnsd)
{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/nsd";
  nsdUser = "nsd";

  # Primary zones = those declared with inline data (everything that isn't a
  # pure secondary). Every primary zonefile must be seeded, or NSD can't serve it.
  primaryZones = lib.filterAttrs (_: zone: (zone.data or "") != "") config.services.nsd.zones;

  # Zones that should be DNSSEC-signed (as declared in ./nsd.nix)
  dnssecZones = lib.filterAttrs (_: zone: zone.dnssec or false) primaryZones;

  # Plain (unsigned) zone data from the git-tracked zone files. Used to seed
  # a fresh NSD host with the raw zone content before it gets signed. Conforms
  # to the zonefile path the nsd module serves from: ${stateDir}/zones/<name>.
  plainZonesDir = pkgs.runCommand "nsd-plain-zones" { } ''
    mkdir -p "$out"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: zone: ''
      cp ${pkgs.writeText "plain-zones-${lib.strings.sanitizeDerivationName name}" zone.data} "$out/${name}"
    '') primaryZones)}
  '';

  # Install the configured TSIG transfer keys into NSD's chroot private dir,
  # mirroring the nsd module's own copyKeys logic (we must re-provide it because
  # we override preStart).
  tsigKeysSetup = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: key: ''
    secret=$(cat "${key.keyFile}")
    install -m 0400 -o ${nsdUser} -g ${nsdUser} <(echo "  secret: \"$secret\"") "${stateDir}/private/${name}"
  '') config.services.nsd.keys);

  # Store-bundled copy of the INWX DS push script, so DS syncing never
  # silently depends on a host path that may be absent.
  pushScript = pkgs.writeShellScript "push-dnssec-to-inwx"
    (builtins.readFile ../scratch/push-dnssec-to-inwx.sh);

in
{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nsd.nix
    ./acme.nix
  ];

  # The module's stock nsd.service preStart does
  #   rm -rf /var/lib/nsd/zones && cp -rL <store>/zones /var/lib/nsd/zones
  # on EVERY start, which destroys the DNSSEC-signed zonefiles produced by
  # nsd-dnssec and leaves NSD serving an unsigned zone on any restart.
  #
  # We replace it so that signed zones are preserved across restarts: the raw
  # (plain) zone data is only seeded when the zonefile does not exist yet (first
  # provision / empty state), and is never clobbered afterwards. That makes
  # DNSSEC signatures persistent and lets a freshly provisioned host come up
  # signed.
  systemd.services.nsd.preStart = lib.mkForce ''
    rm -Rf "${stateDir}/private/"
    rm -Rf "${stateDir}/tmp/"
    install -dm 0700 -o ${nsdUser} -g ${nsdUser} "${stateDir}/private"
    install -dm 0700 -o ${nsdUser} -g ${nsdUser} "${stateDir}/tmp"
    install -dm 0700 -o ${nsdUser} -g ${nsdUser} "${stateDir}/var"
    install -d  -o ${nsdUser} -g ${nsdUser} "${stateDir}/zones"
    install -dm 0750 -o ${nsdUser} -g ${nsdUser} "${stateDir}/dnssec"

    ${tsigKeysSetup}

    # Seed plain zones for signing only when absent, so existing signed
    # zonefiles (and their DS records) survive restarts untouched.
    for z in ${lib.concatStringsSep " " (lib.attrNames primaryZones)}; do
      if [ ! -e "${stateDir}/zones/''$z" ]; then
        cp -L "${plainZonesDir}/''$z" "${stateDir}/zones/''$z"
      fi
    done
  '';

  # DNSSEC signing + DS registration. Runs AFTER nsd.service so the plain zone
  # files are guaranteed to exist (seeded by preStart), then signs them in place
  # and asks NSD to reload. Because preStart no longer wipes the signed zones,
  # the signed state survives restarts, and the module's nsd-dnssec timer keeps
  # re-signing + re-pushing the DS hourly for self-healing.
  systemd.services.nsd-dnssec = lib.mkForce {
    description = "DNSSEC key rollover";
    wantedBy = [ "nsd.service" ];
    after = [ "nsd.service" ];
    path = with pkgs; [ bind nsd curl bash coreutils gnused gnugrep gawk ];
    script =
      let
        zoneScripts = lib.mapAttrsToList (name: zone: ''
          echo "DNSSEC: signing ${name}"
          KEYDIR="${stateDir}/dnssec"
          mkdir -p "$KEYDIR"
          if ! ls "$KEYDIR"/K"${name}".*.key >/dev/null 2>&1; then
            # Refuse to mint fresh keys while the zone still carries DNSSEC
            # records: silently regenerating keys orphans the chain (new
            # DNSKEY, stale DS at the registrar, old RRSIGs). Restore the
            # keys from backup /var/lib/nsd instead.
            if grep -qE '[[:space:]]IN[[:space:]]+DNSKEY[[:space:]]' "${stateDir}/zones/${name}"; then
              echo "ERROR: ${name}: zone is signed but key material is missing in $KEYDIR — restore the keys from backup, do NOT regenerate" >&2
              exit 1
            fi
            cd "$KEYDIR"
            dnssec-keygen -a 13 -f KSK -P now -A now "${name}"
            dnssec-keygen -a 13 -P now -A now "${name}"
            cd - >/dev/null
          fi
          dnssec-signzone -S -K "$KEYDIR" -o "${name}" -O full -N date "${stateDir}/zones/${name}"
          dnssec-verify -o "${name}" "${stateDir}/zones/${name}.signed" \
            || { echo "ERROR: ${name}: dnssec-verify failed — NOT replacing live zone" >&2; exit 1; }
          nsd-checkzone "${name}" "${stateDir}/zones/${name}.signed" \
            && mv -v "${stateDir}/zones/${name}.signed" "${stateDir}/zones/${name}"
        '') dnssecZones;

        localChecks = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: zone: ''
          dig +dnssec "@127.0.0.1" "${name}" SOA +time=3 +tries=1 | grep -q "status: NOERROR" || { echo "ERROR: ${name}: local DNSSEC validation failed after reload" >&2; exit 1; }
        '') dnssecZones);

        externalChecks = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: zone: ''
          ok=""
          for r in 8.8.8.8 1.1.1.1; do
            dig +dnssec +time=4 +tries=1 "@$r" "${name}" SOA 2>/dev/null | grep -q "status: NOERROR" && ok=1
          done
          if [ -z "$ok" ]; then
            echo "WARN: ${name}: no external validating resolver returns NOERROR"
            failures=$((failures + 1))
          fi
        '') dnssecZones);
      in
      ''
        set -e
        ${lib.concatStringsSep "\n" zoneScripts}
        /run/current-system/systemd/bin/systemctl kill -s SIGHUP nsd.service
        sleep 1

        ${lib.concatStringsSep "\n" localChecks}
        echo "DNSSEC: local validation passed"

        # Keep the DS at the registrar (INWX) in sync with the published KSK.
        # Must run BEFORE the external checks: a stale DS is exactly what the
        # external checks would report, and the reconcile fixes it. Invoked
        # through `bash` explicitly — never rely on the shebang, the service
        # PATH lacks /usr/bin/env.
        if [ -x "/root/nixos-config/scratch/push-dnssec-to-inwx.sh" ]; then
          bash "/root/nixos-config/scratch/push-dnssec-to-inwx.sh"
        elif [ -x "${pushScript}" ]; then
          echo "DNSSEC: host copy of push script not found — using store copy"
          bash "${pushScript}"
        else
          echo "ERROR: DS push script unavailable" >&2
          exit 1
        fi

        # End-to-end check through validating resolvers. Three consecutive
        # failures are a hard error (registrar DS almost certainly wrong).
        failures=0
        ${lib.concatStringsSep "\n" externalChecks}
        if [ "$failures" -gt 0 ]; then
          strikes=$(( $(cat "${stateDir}/dnssec/ext-check-failures" 2>/dev/null || echo 0) + 1 ))
          echo "$strikes" > "${stateDir}/dnssec/ext-check-failures"
          if [ "$strikes" -ge 3 ]; then
            echo "ERROR: external DNSSEC validation failed ''${strikes} times in a row — check the DS at the registrar" >&2
            exit 1
          fi
        else
          rm -f "${stateDir}/dnssec/ext-check-failures"
        fi
      '';
    unitConfig.OnFailure = [ "nsd-dnssec-alert.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Notify when the DNSSEC automation fails (signing, verification or DS
  # push). Optional webhook URL in /var/lib/secrets/nsd/alert.url.
  systemd.services.nsd-dnssec-alert = {
    description = "Alert when nsd-dnssec fails";
    path = with pkgs; [ curl coreutils systemd ];
    script = ''
      log=/var/lib/nsd/dnssec/alert-last.log
      host="$(cat /etc/hostname 2>/dev/null || echo nixnsd)"
      {
        echo "=== nsd-dnssec FAILED on $host at $(date -u) ==="
        journalctl -u nsd-dnssec.service --since "1 hour ago" --no-pager 2>/dev/null | tail -n 40
      } > "$log" 2>&1
      if [ -r /var/lib/secrets/nsd/alert.url ]; then
        url="$(cat /var/lib/secrets/nsd/alert.url)"
        curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
          -d '{"topic":"dnssec","message":"nsd-dnssec failed on '"$host"' — see /var/lib/nsd/dnssec/alert-last.log"}' \
          "$url" >/dev/null 2>&1 || true
      fi
      exit 0
    '';
    serviceConfig.Type = "oneshot";
  };

  # Fire a missed hourly re-sign as soon as the host comes back up, and
  # guarantee the hourly schedule explicitly — the stock module timer proved
  # unreliable (last run stayed stuck at Aug 18 for 3 weeks).
  systemd.timers."nsd-dnssec" = lib.mkForce {
    description = "Hourly DNSSEC re-sign and DS sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "30s";
    };
  };

  # Networking
  networking = {
    hostName = "nixnsd";

    # Static IP Configuration matching the nixnsd server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };

  # Disable systemd-resolved to prevent it from binding to port 53
  services.resolved.enable = false;

  environment.systemPackages = with pkgs; [ bind ];
}
