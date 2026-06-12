# NixOS Server Configuration for the Wiki.js Container (nixwikijs)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./wikijs.nix
  ];

  # Networking
  networking = {
    hostName = "nixwikijs";

    # Static IP Configuration matching the nixwikijs server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
