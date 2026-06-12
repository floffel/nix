# NixOS Server Configuration for the PostgreSQL Container (nixpostgres)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./postgresql.nix
  ];

  # Networking
  networking = {
    hostName = "nixpostgres";

    # Static IP Configuration matching the server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
