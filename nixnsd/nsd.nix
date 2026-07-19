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
        dnssec = true;
        dnssecPolicy.algorithm = "ECDSAP256SHA256";
      };
      "floffel.de" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/floffel.de.forward;
        dnssec = true;
        dnssecPolicy.algorithm = "ECDSAP256SHA256";
      };
      "sbminnecker.de" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/sbminnecker.de.forward;
        dnssec = true;
        dnssecPolicy.algorithm = "ECDSAP256SHA256";
      };
      "substitution.art" = {
        provideXFR = commonProvideXFR;
        notify = commonNotify;
        data = builtins.readFile ./zones/substitution.art.forward;
        dnssec = true;
        dnssecPolicy.algorithm = "ECDSAP256SHA256";
      };
    };
  };

  # Announce DNSSEC signatures to secondary nameservers so they include
  # RRSIG records in AXFR responses — this allows resolvers querying the
  # secondary to validate even if the primary is unreachable.
  #
  # NOTE: The NixOS nsd module places extraConfig OUTSIDE the server: block
  # (after all zone: blocks). In NSD 4.x this causes zone-announce-signatures
  # to be misinterpreted as a zone-level tls-auth directive. Until the module
  # supports placing directives inside the server: block, we rely on the
  # NSD default behavior where signatures are announced to secondaries that
  # receive NOTIFYs.
  # services.nsd.extraConfig = ''''
  #   zone-announce-signatures: yes
  # '''';

  systemd.services.nsd = {
    serviceConfig.ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
  };

  # The NixOS NSD module creates nsd-dnssec.service with a unit script that
  # calls ${pkgs.bind}/bin/dnssec-keymgr via an absolute store path. The
  # reference chain from the system toplevel through the unit script to
  # the bind binary is not reliably captured by closure computation, so
  # bind gets garbage collected on deployed containers (nix.gc = weekly).
  # Adding bind to systemPackages forces it into the toplevel's direct
  # dependency tree, protecting both the current and future bind store
  # paths from GC.
  environment.systemPackages = [ pkgs.bind ];
}
