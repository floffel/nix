# NixOS Server Configuration for the Monitoring Container (nixmonitoring)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./monitoring.nix
  ];

  # Networking
  networking = {
    hostName = "nixmonitoring";

    # Static IP Configuration matching the nixmonitoring server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
