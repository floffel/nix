# NixOS Service Configuration for NSD (Authoritative Nameserver)
{ config, pkgs, lib, ... }:

{
  services.nsd = {
    enable = true;
    
    # Listen on all interfaces for public DNS queries and zone transfers
    interfaces = [ "0.0.0.0" "::" ];

    # TSIG key for Hetzner secondary DNS zone transfer authentication
    # Key value is loaded at runtime from a secure mounted folder to prevent leaks
    keys."hetzner-key" = {
      algorithm = "hmac-sha256";
      keyFile = "/var/lib/secrets/nsd/hetzner-key.key";
    };

    # Declarative DNS zones
    zones = {
      "minnecker.com" = {
        # Allow Hetzner's secondary nameservers to fetch zones via AXFR/IXFR
        # Supports both secure TSIG key transfer and IP-based validation fallbacks
        provideXFR = [
          "213.239.242.238 NOKEY"              # ns1.first-ns.de
          "213.133.100.103 NOKEY"              # robotns2.second-ns.de
          "193.47.99.3 NOKEY"                  # robotns3.second-ns.com
          "2a01:4f8:0:a101::a:1 NOKEY"         # ns1.first-ns.de IPv6
          "2a01:4f8:0:1::5ddc:2 NOKEY"         # robotns2.second-ns.de IPv6
          "2001:67c:192c::add:a3 NOKEY"        # robotns3.second-ns.com IPv6
          
          # TSIG-authenticated transfer blocks
          "213.239.242.238 hetzner-key"
          "213.133.100.103 hetzner-key"
          "193.47.99.3 hetzner-key"
          "2a01:4f8:0:a101::a:1 hetzner-key"
          "2a01:4f8:0:1::5ddc:2 hetzner-key"
          "2001:67c:192c::add:a3 hetzner-key"
        ];

        # Notify Hetzner's secondary nameservers when the zone is updated
        notify = [
          "213.239.242.238 NOKEY"
          "213.133.100.103 NOKEY"
          "193.47.99.3 NOKEY"
          "2a01:4f8:0:a101::a:1 NOKEY"
          "2a01:4f8:0:1::5ddc:2 NOKEY"
          "2001:67c:192c::add:a3 NOKEY"
          
          # TSIG-authenticated notify blocks
          "213.239.242.238 hetzner-key"
          "213.133.100.103 hetzner-key"
          "193.47.99.3 hetzner-key"
          "2a01:4f8:0:a101::a:1 hetzner-key"
          "2a01:4f8:0:1::5ddc:2 hetzner-key"
          "2001:67c:192c::add:a3 hetzner-key"
        ];

        # Initial placeholder zone file content to allow nameserver bootup
        data = ''
          $TTL 3600
          @ IN SOA ns1.minnecker.com. admin.minnecker.com. (
              2026061201 ; serial (YYYYMMDDNN)
              86400      ; refresh (24 hours)
              7200       ; retry (2 hours)
              3600000    ; expire (1000 hours)
              3600       ; minimum (1 hour)
          )
          @ IN NS ns1.minnecker.com.
          @ IN NS robotns2.second-ns.de.
          @ IN NS robotns3.second-ns.com.
          ns1 IN A 172.16.16.21
        '';
      };
    };
  };
}
