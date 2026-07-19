# NixOS Server Configuration for the NSD Nameserver Container (nixnsd)
{ config, pkgs, lib, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nsd.nix
    ./acme.nix
  ];

  # The NixOS NSD module pre-signs zones with dnssec-keymgr from bind
  # before starting NSD. This tool was removed in bind 9.20 (nixos-26.05).
  # Override the nsd-dnssec service to use dnssec-keygen (still present)
  # for key generation and dnssec-signzone for signing.
  systemd.services.nsd-dnssec = lib.mkForce {
    description = "DNSSEC key rollover";
    wantedBy = [ "nsd.service" ];
    before = [ "nsd.service" ];
    path = with pkgs; [ bind nsd ];
    script =
      let
        stateDir = "/var/lib/nsd";
        dnssecZones = lib.filterAttrs (_: zone: zone.dnssec or false) config.services.nsd.zones;
        zoneScripts = lib.mapAttrsToList (name: zone: ''
          echo "DNSSEC: signing ${name}"
          KEYDIR="${stateDir}/dnssec"
          mkdir -p "$KEYDIR"
          if ! ls "$KEYDIR/K${name}."*".key" >/dev/null 2>&1; then
            ORIGDIR="$PWD"; cd "$KEYDIR"
            dnssec-keygen -a 13 -f KSK "${name}"
            dnssec-keygen -a 13 "${name}"
            cd "$ORIGDIR"
          fi
          dnssec-signzone -S -K "$KEYDIR" -o "${name}" -O full -N date \
            "${stateDir}/zones/${name}"
          nsd-checkzone "${name}" "${stateDir}/zones/${name}.signed" \
            && mv -v "${stateDir}/zones/${name}.signed" "${stateDir}/zones/${name}"
        '') dnssecZones;
      in
      ''
        set -e
        install -m 0600 -o nsd -g nsd -d "${stateDir}/dnssec"
        ${lib.concatStringsSep "\n" zoneScripts}
      '';
    postStop = ''
      /run/current-system/systemd/bin/systemctl kill -s SIGHUP nsd.service
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
}
