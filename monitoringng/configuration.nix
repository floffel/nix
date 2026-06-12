# NixOS Server Configuration for the Monitoring Container (monitoringng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./monitoring.nix
  ];

  # Networking
  networking = {
    hostName = "monitoringng";

    # Static IP Configuration matching the monitoringng server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
