# NixOS Service Configuration for Unbound (Recursive DNS Resolver)
{ config, pkgs, lib, ... }:

{
  services.unbound = {
    enable = true;

    # Use extraConfig for the complete unbound.conf — the NixOS 26.05
    # unbound module's `settings` serializer outputs server-section
    # keywords outside the `server:` block, causing unbound 1.25 to
    # reject them as unknown keywords.
    settings = {};

    extraConfig = ''
      server:
          interface: 0.0.0.0
          interface: ::
          access-control: 127.0.0.0/8 allow
          access-control: ::1 allow
          access-control: 10.10.10.0/24 allow
          access-control: 10.20.20.0/24 allow
          access-control: fd00::/64 allow
          access-control: fd01::/64 allow
          tls-port: 8853
          tls-service-key: "/var/lib/secrets/ssl/minnecker.com/key.pem"
          tls-service-pem: "/var/lib/secrets/ssl/minnecker.com/fullchain.pem"
          harden-glue: yes
          harden-dnssec-stripped: yes
          harden-below-nxdomain: yes
          harden-referral-path: yes
          max-cache-ttl: 3600
          cache-min-ttl: 60
          neg-cache-size: 16M
          num-threads: 4
          msg-cache-size: 128M
          private-address: 10.0.0.0/8
          private-address: 172.16.0.0/12
          private-address: 192.168.0.0/16
          private-address: fc00::/7
          private-address: fd00::/8
          private-address: ::ffff:0:0/96
          ratelimit: 500
          prefetch: yes
          serve-expired: yes
          auto-trust-anchor-file: "/var/unbound/root.key"

      stub-zone:
          name: "minnecker.com."
          stub-addr: 10.20.20.11

      stub-zone:
          name: "floffel.de."
          stub-addr: 10.20.20.11

      stub-zone:
          name: "sbminnecker.de."
          stub-addr: 10.20.20.11

      stub-zone:
          name: "substitution.art."
          stub-addr: 10.20.20.11

      forward-zone:
          name: "."
          forward-addr: 1.1.1.1
          forward-addr: 1.0.0.1
          forward-addr: 8.8.8.8
    '';
  };
}
