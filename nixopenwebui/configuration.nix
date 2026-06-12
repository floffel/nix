# NixOS Server Configuration for the Open WebUI Container (nixopenwebui)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./open-webui.nix
  ];

  # Networking
  networking = {
    hostName = "nixopenwebui";

    # Static IP Configuration matching the nixopenwebui server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
