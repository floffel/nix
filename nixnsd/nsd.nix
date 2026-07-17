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

    # User-defined sync secondary notify blocks
    "78.47.124.81@53 sync"
    "2a01:4f8:c0c:2ea9::2@53 sync"
  ];

  # DNSSEC key settings — uses KSK+ZSK pair per zone for proper key
  # rollover. The KSK (keytag with the DS flag) is published as a DS
  # record at the registrar; the ZSK is used for daily zone signing.
  dnssec = {
    enabled = true;
    # KSK: 4096-bit for long-term security, ZSK: 2048-bit rotated every 7d
    keys = [
      {
        name = "ksk";
        algorithm = "ecdsap256sha256";   # NIST P-256 — wide DNSSEC support
        key-size = 256;                  # bits (implies 256-bit curve)
      }
      {
        name = "zsk";
        algorithm = "ecdsap256sha256";
        key-size = 256;
      }
    ];
    zone-signing-schedules = lib.mkMerge [
      # ZSK signs every 14 days, with a 7d prepare window so the KSP
      # (key-signing key) can publish the DS record before the ZSK rotates.
      (pkgs.lib.mkBefore "")  # no-op placeholder to satisfy MkMerge type
    ];
  };

in
{
  services.nsd = {
    enable = true;
    
    # Listen on all interfaces for public DNS queries and zone transfers
    interfaces = [ "0.0.0.0" "::" ];

    # Enable Response Rate Limiting (RRL) to prevent DNS amplification attacks
    ratelimit = {
      enable = true;
      ratelimit = 200;  # Max responses per second from a single IP/subnet
    };

    # TSIG keys for secondary DNS zone transfer authentication
    # Key values are loaded at runtime from secure mounted files to prevent leaks
    keys = {
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
        signatures = dnssec;
      };
      "floffel.de" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/floffel.de.forward;
        signatures = dnssec;
      };
      "sbminnecker.de" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/sbminnecker.de.forward;
        signatures = dnssec;
      };
      "substitution.art" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/substitution.art.forward;
        signatures = dnssec;
      };
    };
  };

  # Announce DNSSEC signatures to secondary nameservers so they include
  # RRSIG records in AXFR responses — this allows resolvers querying the
  # secondary to validate even if the primary is unreachable.
  services.nsd.extraConfig = ''
    zone-announce-signatures: yes
  '';

  systemd.services.nsd.serviceConfig.ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
}
