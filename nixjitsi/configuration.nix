# NixOS Server Configuration for the Jitsi Container (nixjitsi)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./jitsi.nix
  ];

  # Networking
  networking = {
    hostName = "nixjitsi";

    # Static IP Configuration matching the nixjitsi server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
