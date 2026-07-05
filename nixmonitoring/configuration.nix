# NixOS Server Configuration for the Monitoring Container (nixmonitoring)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./monitoring.nix
  ];

  # Networking
  networking = {
    hostName = "nixmonitoring";

    # Static IP Configuration matching the nixmonitoring server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };
  };

  # Static route to reach the wireguard container (nixwireguard at 10.10.10.5)
  # which sits on the 10.10.10.0/24 WAN subnet, not the 10.20.20.0/24 service
  # LAN. The Proxmox host (10.20.20.1) has interfaces on both bridges and
  # routes between them, so traffic to 10.10.10.0/24 goes via the Proxmox host.
  # Without this route, Prometheus can't scrape node_exporter on nixwireguard.
  # Uses an explicit systemd service rather than networking.static.routes because
  # the Proxmox LXC module uses systemd-networkd, which can override the
  # scripted static-route mechanism.
  systemd.services.wireguard-route = {
    description = "Add static route to wireguard container subnet";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.iproute2 ];
    script = ''
      ip route add 10.10.10.0/24 via 10.20.20.1 2>/dev/null || true
    '';
  };
}
