# NixOS Server Configuration for the Vaultwarden Container (vaultwardenng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./vaultwarden.nix
  ];

  # Networking
  networking = {
    hostName = "vaultwardenng";

    # Static IP Configuration matching the vaultwardenng server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
