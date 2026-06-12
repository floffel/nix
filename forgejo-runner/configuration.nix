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
    hostName = "gitea-runner";

    # Static IP Configuration matching the server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
