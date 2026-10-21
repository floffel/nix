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

  # sbminni.de is served/signed here but its NS delegation is switched to us
  # separately. Until that happens, public resolvers cannot answer for it, so
  # exclude it from the external validation checks (local checks still apply).
  # Remove the exclusion once the delegation is live.
  externalCheckZones = lib.filterAttrs (name: _: name != "sbminni.de") dnssecZones;

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

  # Replace the SOA serial with a strictly increasing value before signing.
  # `dnssec-signzone -N date` can produce a lower serial than the zone already
  # served by a secondary (it resets the per-day counter), which makes the
  # secondary refuse the transfer. We therefore pin the serial ourselves and
  # sign with -N keep.
  serialHelpers = ''
    bump_serial() {
      local file="$1" newserial="$2" tmp
      tmp="$file.serial.tmp"
      awk -v s="$newserial" '
        BEGIN { in_soa=0; replaced=0 }
        {
          start=1
          if (!in_soa && $0 ~ /IN[[:space:]]+SOA/) {
            in_soa=1
            for (i=1; i<=NF; i++) if ($i == "SOA") { start=i+1; break }
          }
          if (in_soa && !replaced) {
            for (i=start; i<=NF; i++) {
              if ($i ~ /^[0-9]+$/) { $i=s; replaced=1; break }
            }
          }
          print
          if (in_soa && $0 ~ /\)/) { in_soa=0 }
        }
      ' "$file" > "$tmp" && mv "$tmp" "$file"
    }
  '';

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
    # `bind` provides the dnssec-* signing tools; `dnsutils` is a separate
    # output that carries dig/host/nslookup. Without it the localChecks below
    # fail with "dig: command not found".
    path = with pkgs; [ bind dnsutils nsd curl bash coreutils gnused gnugrep gawk ];
    script =
      let
        zoneScripts = lib.mapAttrsToList (name: zone: ''
          echo "DNSSEC: signing ${name}"
          KEYDIR="${stateDir}/dnssec"
          ZONEFILE="${stateDir}/zones/${name}"
          SOURCE="${plainZonesDir}/${name}"
          HASHFILE="${stateDir}/dnssec/${name}.source.sha256"
          mkdir -p "$KEYDIR"
          if ! ls "$KEYDIR"/K"${name}".*.key >/dev/null 2>&1; then
            # Refuse to mint fresh keys while the zone still carries DNSSEC
            # records: silently regenerating keys orphans the chain (new
            # DNSKEY, stale DS at the registrar, old RRSIGs). Restore the
            # keys from backup /var/lib/nsd instead.
            if grep -qE '[[:space:]]IN[[:space:]]+DNSKEY[[:space:]]' "$ZONEFILE"; then
              echo "ERROR: ${name}: zone is signed but key material is missing in $KEYDIR — restore the keys from backup, do NOT regenerate" >&2
              exit 1
            fi
            cd "$KEYDIR"
            dnssec-keygen -a 13 -f KSK -P now -A now "${name}"
            dnssec-keygen -a 13 -P now -A now "${name}"
            cd - >/dev/null
          fi

          # Re-seed when the git-tracked plain zone changed. The new source is
          # signed in a temporary file and only replaces the live zone after
          # both dnssec-verify and nsd-checkzone succeed, so a broken zone
          # edit cannot take the live zone down.
          NEWSHA=$(sha256sum "$SOURCE" | cut -d' ' -f1)
          OLDSHA=$(cat "$HASHFILE" 2>/dev/null || true)
          INPUT="$ZONEFILE"
          RESEED=0
          if [ "$NEWSHA" != "$OLDSHA" ]; then
            echo "DNSSEC: ${name}: zone source changed, re-seeding from git"
            INPUT="${stateDir}/zones/${name}.source"
            cp -L "$SOURCE" "$INPUT"
            RESEED=1
          fi

          LIVE_SERIAL=$(dig +short "@127.0.0.1" "${name}" SOA +time=3 +tries=1 2>/dev/null | awk '{print $3}' | head -1)
          case "$LIVE_SERIAL" in ""|*[!0-9]*) LIVE_SERIAL=0 ;; esac
          BASE=$(( $(date +%Y%m%d) * 100 + 99 ))
          if [ "$LIVE_SERIAL" -ge "$BASE" ]; then
            NEW_SERIAL=$((LIVE_SERIAL + 1))
          else
            NEW_SERIAL=$BASE
          fi
          bump_serial "$INPUT" "$NEW_SERIAL"
          dnssec-signzone -S -K "$KEYDIR" -o "${name}" -O full -N keep "$INPUT"
          dnssec-verify -o "${name}" "$INPUT.signed" \
            || { echo "ERROR: ${name}: dnssec-verify failed — NOT replacing live zone" >&2; rm -f "$INPUT.signed"; [ "$RESEED" = 1 ] && rm -f "$INPUT"; exit 1; }
          nsd-checkzone "${name}" "$INPUT.signed" \
            || { echo "ERROR: ${name}: nsd-checkzone failed — NOT replacing live zone" >&2; rm -f "$INPUT.signed"; [ "$RESEED" = 1 ] && rm -f "$INPUT"; exit 1; }
          mv -v "$INPUT.signed" "$ZONEFILE"
          if [ "$RESEED" = 1 ]; then
            echo "$NEWSHA" > "$HASHFILE"
            rm -f "$INPUT"
          fi
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
        '') externalCheckZones);
      in
      ''
        set -e
        ${serialHelpers}
        ${lib.concatStringsSep "\n" zoneScripts}
        /run/current-system/systemd/bin/systemctl kill -s SIGHUP nsd.service
        sleep 1

        ${localChecks}
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
        ${externalChecks}
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
      # Deliberately NOT RemainAfterExit: a timer fires a *start* job, and a
      # oneshot unit left "active (exited)" after its first run makes every
      # subsequent start job a no-op — so the hourly timer would never re-sign
      # and the 30-day RRSIGs would silently lapse (SERVFAIL on validators).
      # Returning to "inactive" after each run lets the timer start it again.
      Type = "oneshot";
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

  # Enforce the central CrowdSec decisions on the directly-exposed DNS port.
  services.crowdsec-firewall-bouncer = {
    enable = true;
    registerBouncer.enable = false;
    secrets.apiKeyPath = "/var/lib/crowdsec/nsd-bouncer.key";
    settings.api_url = "http://10.20.20.14:8080";
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
