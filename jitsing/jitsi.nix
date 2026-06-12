# NixOS Service Configuration for Jitsi Meet
{ config, pkgs, lib, ... }:

{
  nixpkgs.config.permittedInsecurePackages = [
    "jitsi-meet-1.0.8792"
  ];

  services.jitsi-meet = {
    enable = true;
    hostName = "meet.minnecker.com";
    
    # Enable Nginx on the local container to serve the web assets
    nginx.enable = true;
  };

  # Disable ACME and ForceSSL locally so traffic can be proxied over HTTP
  services.nginx.virtualHosts."meet.minnecker.com" = {
    enableACME = false;
    forceSSL = false;
  };

  services.jitsi-videobridge = {
    enable = true;
    # Configure NAT settings to allow WebRTC connections from outside
    nat = {
      localAddress = "172.16.16.20";
      # Public address of the server (domain name or WAN IP)
      publicAddress = "meet.minnecker.com";
    };
  };
}
