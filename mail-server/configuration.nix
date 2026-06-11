# NixOS Server Configuration for the Mail Server Container
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./mail-server.nix
  ];

  # Networking
  networking = {
    hostName = "backendmail";

    # Static IP Configuration matching the mail server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
