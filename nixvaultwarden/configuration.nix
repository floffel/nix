# NixOS Server Configuration for the Vaultwarden Container (nixvaultwarden)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./vaultwarden.nix
  ];

  # Networking
  networking = {
    hostName = "nixvaultwarden";

    # Static IP Configuration matching the nixvaultwarden server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
