# NixOS Server Configuration for the NSD Nameserver Container (nixnsd)
{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/nsd";
  nsdUser = "nsd";

  # Zones that should be DNSSEC-signed (as declared in ./nsd.nix)
  dnssecZones = lib.filterAttrs (_: zone: zone.dnssec or false) config.services.nsd.zones;

  # Plain (unsigned) zone data from the git-tracked zone files. Used to seed
  # a fresh NSD host with the raw zone content before it gets signed. Conforms
  # to the zonefile path the nsd module serves from: ${stateDir}/zones/<name>.
  plainZonesDir = pkgs.runCommand "nsd-plain-zones" { } ''
    mkdir -p "$out"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: zone: ''
      cp ${pkgs.writeText "plain-zones-${lib.strings.sanitizeDerivationName name}" zone.data} "$out/${name}"
    '') dnssecZones)}
  '';

  # Install the configured TSIG transfer keys into NSD's chroot private dir,
  # mirroring the nsd module's own copyKeys logic (we must re-provide it because
  # we override preStart).
  tsigKeysSetup = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: key: ''
    secret=$(cat "${key.keyFile}")
    install -m 0400 -o ${nsdUser} -g ${nsdUser} <(echo "  secret: \"$secret\"") "${stateDir}/private/${name}"
  '') config.services.nsd.keys);

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
    for z in ${lib.concatStringsSep " " (lib.attrNames dnssecZones)}; do
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
    path = with pkgs; [ bind nsd curl ];
    script =
      let
        zoneScripts = lib.mapAttrsToList (name: zone: ''
          echo "DNSSEC: signing ${name}"
          KEYDIR="${stateDir}/dnssec"
          mkdir -p "$KEYDIR"
          if ! ls "$KEYDIR/K${name}."*".key" >/dev/null 2>&1; then
            cd "$KEYDIR"
            dnssec-keygen -a 13 -f KSK -P now -A now "${name}"
            dnssec-keygen -a 13 -P now -A now "${name}"
            cd - >/dev/null
          fi
          dnssec-signzone -S -K "$KEYDIR" -o "${name}" -O full -N date \
            "${stateDir}/zones/${name}"
          nsd-checkzone "${name}" "${stateDir}/zones/${name}.signed" \
            && mv -v "${stateDir}/zones/${name}.signed" "${stateDir}/zones/${name}"
        '') dnssecZones;
      in
      ''
        set -e
        ${lib.concatStringsSep "\n" zoneScripts}
        /run/current-system/systemd/bin/systemctl kill -s SIGHUP nsd.service

        # Push new DS records to INWX registrar (idempotent per KSK).
        if [ -x /root/nixos-config/scratch/push-dnssec-to-inwx.sh ]; then
          echo "DNSSEC: pushing DS records to INWX..."
          /root/nixos-config/scratch/push-dnssec-to-inwx.sh || echo "DNSSEC: WARNING - INWX push failed (check /var/lib/secrets/nsd/inwx.env)"
        fi
      '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
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
