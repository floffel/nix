# NixOS Server Configuration for the NSD Nameserver Container (nixnsd)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nsd.nix
    ./acme.nix
  ];

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
