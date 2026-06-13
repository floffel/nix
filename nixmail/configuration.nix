# NixOS Server Configuration for the Mail Server Container
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nixmail.nix
  ];

  programs.nix-ld.enable = true;
  # Networking
  networking = {
    hostName = "nixmail";

    # Static IP Configuration matching the mail server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
