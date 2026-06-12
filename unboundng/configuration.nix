# NixOS Server Configuration for the Unbound DNS Resolver Container (unboundng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./unbound.nix
  ];

  # Networking
  networking = {
    hostName = "unboundng";

    # Static IP Configuration matching the unboundng server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
