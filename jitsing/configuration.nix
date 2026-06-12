# NixOS Server Configuration for the Jitsi Container (jitsing)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./jitsi.nix
  ];

  # Networking
  networking = {
    hostName = "jitsing";

    # Static IP Configuration matching the jitsing server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
