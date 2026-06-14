# NixOS Service Configuration for Unbound (Recursive DNS Resolver)
{ config, pkgs, lib, ... }:

{
  services.unbound = {
    enable = true;

    # Configure unbound.conf declaratively
    settings = {
      server = {
        # Listen on all interfaces on port 53
        interface = [ "0.0.0.0" "::" ];

        # Allow access from localhost and our private container subnet
        access-control = [
          "127.0.0.0/8 allow"
          "::1 allow"
          "10.20.20.0/24 allow"
          "fd01::/64 allow"
        ];
      };

      # Forward local domain queries to the authoritative NSD nameserver
      stub-zone = [
        {
          name = "minnecker.com.";
          stub-addr = "10.20.20.11"; # nixnsd container IP
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

      # Forward all other public queries to upstream resolvers (configured fallbacks)
      forward-zone = [
        {
          name = ".";
          forward-addr = [
            "185.12.64.1" # Fallback 1 (IPv4)
            "2a01:4ff:ff00::add:2" # Fallback (IPv6)
            "185.12.64.2" # Fallback 2 (IPv4)
          ];
        }
      ];
    };
  };
}
