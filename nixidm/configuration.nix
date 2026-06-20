# NixOS Server Configuration for the Kanidm Container (idmng)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./kanidm.nix
  ];

  # Networking
  networking = {
    hostName = "nixidm";

    # Static IP Configuration matching the server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };
  environment.systemPackages = with pkgs; [
    kanidm_1_10
  ];

  # CLI client config for manual administration (kanidm login -D admin, etc.).
  # The declarative provisioning hook uses services.kanidm.provision.instanceUrl
  # directly and does not rely on this file.
  environment.etc."kanidm/config".text = ''
    uri = "https://localhost:8443"
    verify_ca = false
  '';
}
