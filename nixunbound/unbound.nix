# NixOS Service Configuration for Unbound (Recursive DNS Resolver)
{ config, pkgs, lib, ... }:

{
  services.unbound = {
    enable = true;

    settings = {
      server = {
        interface = [ "0.0.0.0" "::" ];

        access-control = [
          "127.0.0.0/8 allow"
          "::1 allow"
          "10.10.10.0/24 allow"
          "10.20.20.0/24 allow"
          "fd00::/64 allow"
          "fd01::/64 allow"
        ];

        tls-port = 8853;
        tls-service-key = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        tls-service-pem = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";

        harden-glue = "yes";
        harden-dnssec-stripped = "yes";
        harden-below-nxdomain = "yes";
        harden-referral-path = "yes";

        cache-min-ttl = 60;
        neg-cache-size = "16M";
        num-threads = 4;
        msg-cache-size = "128M";

        private-address = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "fc00::/7"
          "fd00::/8"
          "::ffff:0:0/96"
        ];

        ratelimit = 500;
        prefetch = "yes";
        serve-expired = "yes";
      };

      stub-zone = [
        {
          name = "minnecker.com.";
          stub-addr = "10.20.20.11";
        }
        {
          name = "floffel.de.";
          stub-addr = "10.20.20.11";
        }
        {
          name = "sbminnecker.de.";
          stub-addr = "10.20.20.11";
        }
        {
          name = "substitution.art.";
          stub-addr = "10.20.20.11";
        }
      ];

      forward-zone = [
        {
          name = ".";
          forward-addr = [
            "1.1.1.1"
            "1.0.0.1"
            "8.8.8.8"
          ];
        }
      ];
    };
  };
}
