# NixOS Server Configuration for the Mail Server Container
{ config, pkgs, lib, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nixmail.nix
  ];

  programs.nix-ld.enable = true;
  # Networking
  networking = {
    hostName = "nixmail";

    # Use the local recursive resolver (nixunbound) for all DNS. The Hetzner
    # public resolvers in hosts.nix cause Spamhaus/DNSBL queries to be refused
    # with 127.255.255.254; full recursion from nixunbound is allowed.
    nameservers = lib.mkForce [ "10.20.20.16" "fd01::16" ];

    # Static IP Configuration matching the mail server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
}
