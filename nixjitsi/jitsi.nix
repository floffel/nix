# NixOS Service Configuration for Jitsi Meet
{ config, pkgs, lib, ... }:

{
  nixpkgs.config.permittedInsecurePackages = [
    "jitsi-meet-1.0.8792"
  ];

  # The logrotate-checkconf.service runs as root without capabilities and fails
  # inside this unprivileged LXC: its `su nginx nginx` switch cannot traverse
  # the 750 nginx-owned log directory, producing a false "Permission denied".
  # The actual logrotate.service (which does the rotation) keeps working.
  systemd.services.logrotate-checkconf.enable = false;

  # A reverse proxy sits in front of this container, so nginx here sees little
  # direct traffic. The NixOS nginx module registers a logrotate block under the
  # `nginx` key (weekly, rotate 26); override the same key so we merge into one
  # block and cap retention to avoid unbounded growth: rotate daily, keep only
  # a few compressed archives, and trigger early rotation on size so the total
  # stays well under ~500 MB.
  services.logrotate.settings.nginx = {
    frequency = "daily";
    rotate = 3;
    maxsize = "100M";
  };

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
    # The nixnginx front proxy (10.20.20.14 on the service LAN) already
    # terminates TLS and forwards X-Forwarded-For. Rewrite $remote_addr to the
    # real client IP here so Prosody/Jicofo and the Jitsi web app see it
    # directly instead of the proxy address.
    extraConfig = ''
      set_real_ip_from 10.20.20.14;
      set_real_ip_from fd01::14;
      real_ip_header X-Forwarded-For;
      real_ip_recursive on;
    '';
  };

  services.jitsi-videobridge = {
    enable = true;
    # Configure NAT settings to allow WebRTC connections from outside
    nat = {
      localAddress = "10.20.20.22";
      # Public address of the server (domain name or WAN IP)
      publicAddress = "meet.minnecker.com";
    };
  };
}
