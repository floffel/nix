# NixOS Server Configuration for the Unbound DNS Resolver Container (nixunbound)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./unbound.nix
  ];

  # Networking
  networking = {
    hostName = "nixunbound";

    # Static IP Configuration matching the nixunbound server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
