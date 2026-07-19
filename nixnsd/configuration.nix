# NixOS Server Configuration for the NSD Nameserver Container (nixnsd)
{ config, pkgs, lib, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nsd.nix
    ./acme.nix
  ];

  # The nixpkgs bind derivation's enablePython flag adds Python as a build
  # input but never passes --with-python to configure, so dnssec-keymgr
  # (a Python script needed by NSD's DNSSEC key rollover) is never built.
  # This overlay forces --with-python into bind's configureFlags so the
  # NixOS NSD module's dnssecTools = pkgs.bind.override { enablePython = true; }
  # actually produces a bind with the Python tools.
  nixpkgs.overlays = [
    (final: prev: {
      bind = prev.bind.overrideAttrs (old: {
        configureFlags = (old.configureFlags or []) ++ [ "--with-python" ];
      });
    })
  ];

  # Networking
  networking = {
    hostName = "nixnsd";

    # Static IP Configuration matching the nixnsd server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };

  # Disable systemd-resolved to prevent it from binding to port 53
  services.resolved.enable = false;
}
