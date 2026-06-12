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
          "172.16.16.0/24 allow"
          "fd0c:dead:beef::/64 allow"
        ];
      };

      # Forward local domain queries to the authoritative NSD nameserver
      stub-zone = [
        {
          name = "minnecker.com.";
          stub-addr = "172.16.16.21"; # nsdng container IP
        }
      ];

      # Forward all other public queries to upstream resolvers (Cloudflare / Google)
      forward-zone = [
        {
          name = ".";
          forward-addr = [
            "1.1.1.1" # Cloudflare Primary
            "1.0.0.1" # Cloudflare Secondary
            "8.8.8.8" # Google Primary
          ];
        }
      ];
    };
  };
}
