# NixOS Server Configuration for the NSD Nameserver Container (nsdng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nsd.nix
  ];

  # Networking
  networking = {
    hostName = "nsdng";

    # Static IP Configuration matching the nsdng server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
