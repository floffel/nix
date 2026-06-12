# NixOS Service Configuration for NSD (Authoritative Nameserver)
{ config, pkgs, lib, ... }:

let
  # Common secondary nameservers for zone transfers and notifications
  commonProvideXFR = [
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

    # User-defined sync secondary transfer blocks
    "78.47.124.81 sync"
    "2a01:4f8:c0c:2ea9::2 sync"
  ];

  commonNotify = [
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

    # User-defined sync secondary notify blocks
    "78.47.124.81@53 sync"
    "2a01:4f8:c0c:2ea9::2@53 sync"
  ];
in
{
  services.nsd = {
    enable = true;
    
    # Listen on all interfaces for public DNS queries and zone transfers
    interfaces = [ "0.0.0.0" "::" ];

    # TSIG keys for secondary DNS zone transfer authentication
    # Key values are loaded at runtime from secure mounted files to prevent leaks
    keys = {
      "hetzner-key" = {
        algorithm = "hmac-sha256";
        keyFile = "/var/lib/secrets/nsd/hetzner-key.key";
      };
      "sync" = {
        algorithm = "hmac-sha256";
        keyFile = "/var/lib/secrets/nsd/sync.key";
      };
    };

    # Declarative DNS zones loaded from version-controlled git zone files
    zones = {
      "minnecker.com" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/minnecker.com.forward;
      };
      "floffel.de" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/floffel.de.forward;
      };
      "sbminnecker.de" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/sbminnecker.de.forward;
      };
      "substitution.art" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/substitution.art.forward;
      };
    };
  };
}
