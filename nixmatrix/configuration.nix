# NixOS Server Configuration for the Matrix Synapse Container (nixmatrix)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./synapse.nix
  ];

  # Networking
  networking = {
    hostName = "nixmatrix";

    # Static IP Configuration matching the nixmatrix server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
