# NixOS Server Configuration for the JupyterLab Container (nixjupyter)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./jupyter.nix
  ];

  networking = {
    hostName = "nixjupyter";

    # Static IP assigned by Proxmox; see the pct create block in README.md.
    useDHCP = false;

    # The container sits behind nixnginx and the host firewall; no in-guest
    # filtering, matching every other service container here.
    firewall = {
      enable = false;
    };
  };
}
