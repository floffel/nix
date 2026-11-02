# NixOS Server Configuration for the Immich Container (niximmich)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./immich.nix
  ];

  networking = {
    hostName = "niximmich";
    useDHCP = false;

    # Reachability is handled by the Proxmox bridge and nixnginx; the same
    # convention as every other container in this repository.
    firewall = {
      enable = false;
    };
  };
}
