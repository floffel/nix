# NixOS Server Configuration for the Paperless-ngx Container (nixpaperless)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./paperless.nix
  ];

  # Networking
  networking = {
    hostName = "nixpaperless";

    # Static IP Configuration matching the nixpaperless server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
