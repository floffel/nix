# NixOS Server Configuration for the Open WebUI Container (openwebuing)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./open-webui.nix
  ];

  # Networking
  networking = {
    hostName = "openwebuing";

    # Static IP Configuration matching the openwebuing server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
