# NixOS Server Configuration for the Nginx Reverse Proxy Container (nginxng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nginx.nix
  ];

  # Networking
  networking = {
    hostName = "nginxng";

    # Static IP Configuration matching the nginxng server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
