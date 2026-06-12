# NixOS Server Configuration for the Wiki.js Container (wikijsng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./wikijs.nix
  ];

  # Networking
  networking = {
    hostName = "wikijsng";

    # Static IP Configuration matching the wikijsng server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
