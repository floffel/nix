# NixOS Server Configuration for the NSD Nameserver Container (nixnsd)
{ config, pkgs, lib, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nsd.nix
    ./acme.nix
  ];

  # The NixOS NSD module creates nsd-dnssec.service which calls
  # dnssec-keymgr from bind. This tool was removed in bind 9.20
  # (shipped by nixos-26.05). The service fails with exit 127.
  # Existing DNSSEC zones are already signed and continue to work;
  # key rollover must be handled manually until the NixOS module
  # is updated for bind 9.20.
  systemd.suppressedSystemUnits = [ "nsd-dnssec.service" "nsd-dnssec.timer" ];

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
