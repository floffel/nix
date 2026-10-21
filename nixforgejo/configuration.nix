# NixOS Server Configuration for the Forgejo Container (forgejo)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./forgejo.nix
  ];

  # Enforce the central CrowdSec decisions on the directly-exposed SSH port.
  services.crowdsec-firewall-bouncer = {
    enable = true;
    registerBouncer.enable = false;
    secrets.apiKeyPath = "/var/lib/crowdsec/forgejo-bouncer.key";
    settings.api_url = "http://10.20.20.14:8080";
  };

  # Networking
  networking = {
    hostName = "nixforgejo";

    # Static IP Configuration matching the server setup
    useDHCP = false;

    # Firewall configuration
    firewall = {
      enable = false;
      allowedTCPPorts = [ 2222 ];
    };
  };
}
