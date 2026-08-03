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

    # Ensure proper DNS resolution from within the container
    # (systemd-networkd should handle this via proxmoxLXC, but
    #  explicitly setting nameservers guarantees resolv.conf is correct)
    nameservers = [ "10.20.20.16" "185.12.64.1" ];

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
