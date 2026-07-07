# NixOS Server Configuration for the Nginx Reverse Proxy Container (nixnginx)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nginx.nix
  ];

  # Networking
  networking = {
    hostName = "nixnginx";

    # Static IP Configuration matching the nixnginx server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };

    # Pin the public service hostnames to the local nginx reverse proxy.
    #
    # Hairpin NAT on the Proxmox host routes cross-container traffic destined
    # for the public IP back to nixnginx — but it CANNOT handle the
    # self-referential case where nixnginx itself curls a *.minnecker.com URL
    # (e.g. Nextcloud's user_oidc discovery fetch against idm.minnecker.com).
    # The kernel drops the DNAT'd loopback packet (src=10.20.20.14
    # dst=10.20.20.14) before it reaches the nat POSTROUTING hook, so no SNAT
    # rule can rescue it. Resolving the public hostnames to nixnginx's own
    # address locally avoids the round trip entirely: the kernel connects
    # directly to its own nginx listener on :443, still going through the full
    # TLS + vhost + proxy_pass chain (same certs, same upstreams). Only this
    # container is affected; other containers keep using hairpin.
    extraHosts = ''
      10.20.20.14 idm.minnecker.com
      fd01::14 idm.minnecker.com
      10.20.20.14 cloud.minnecker.com
      fd01::14 cloud.minnecker.com
      10.20.20.14 git.minnecker.com
      fd01::14 git.minnecker.com
      10.20.20.14 monitoring.minnecker.com
      fd01::14 monitoring.minnecker.com
      10.20.20.14 matrix.minnecker.com
      fd01::14 matrix.minnecker.com
      10.20.20.14 ai.minnecker.com
      fd01::14 ai.minnecker.com
      10.20.20.14 kie.minnecker.com
      fd01::14 kie.minnecker.com
      10.20.20.14 mail.minnecker.com
      fd01::14 mail.minnecker.com
      10.20.20.14 vault.minnecker.com
      fd01::14 vault.minnecker.com
      10.20.20.14 wiki.minnecker.com
      fd01::14 wiki.minnecker.com
      10.20.20.14 meet.minnecker.com
      fd01::14 meet.minnecker.com
      10.20.20.14 www.minnecker.com minnecker.com
      fd01::14 www.minnecker.com minnecker.com
    '';
  };
}
