# NixOS Server Configuration for the Forgejo Container (forgejo)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./forgejo.nix
  ];

  # Networking
  networking = {
    hostName = "nixforgejo";

    # Static IP Configuration matching the server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
