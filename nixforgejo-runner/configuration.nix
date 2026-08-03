# NixOS Server Configuration for the Gitea Actions Runner Container (gitea-runner)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./runner.nix
  ];

  # Networking
  networking = {
    hostName = "nixforgejo-runner";

    # Static IP Configuration matching the server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };

  # Disable systemd-resolved — the Proxmox LXC pushes public DNS servers
  # that don't know about local domains (git.minnecker.com, etc.).
  # Fall back to static /etc/resolv.conf from hosts.nix which points to
  # the local Unbound resolver at 10.20.20.16.
  services.resolved.enable = false;
}
