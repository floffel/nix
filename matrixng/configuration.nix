# NixOS Server Configuration for the Matrix Synapse Container (matrixng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./synapse.nix
  ];

  # Networking
  networking = {
    hostName = "matrixng";

    # Static IP Configuration matching the matrixng server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
