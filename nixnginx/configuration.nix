# NixOS Server Configuration for the Nginx Reverse Proxy Container (nixnginx)
{ config, pkgs, lib, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nginx.nix
  ];

  # GnuPG for the Roundcube Enigma plugin; rspamc for markasjunk learning.
  environment.systemPackages = [ pkgs.gnupg pkgs.rspamd ];

  # Enigma PGP support in Roundcube.
  systemd.tmpfiles.rules = [
    "d /var/lib/roundcube/enigma 0700 nginx nginx -"
    "d /var/lib/crowdsec/state 0750 crowdsec crowdsec - -"
    "L+ /var/lib/crowdsec/state/GeoLite2-City.mmdb - - - - ${pkgs.dbip-city-lite}/share/dbip/dbip-city-lite.mmdb"
    "L+ /var/lib/crowdsec/state/GeoLite2-ASN.mmdb - - - - ${pkgs.dbip-asn-lite}/share/dbip/dbip-asn-lite.mmdb"
  ];
  systemd.services.phpfpm-roundcube.path = [ pkgs.gnupg ];

  # Fail2ban — brute-force and scan protection in front of all public vhosts.
  # CrowdSec: parses nginx access/error logs from journald and blocks the
  # offending source IP at the firewall. It replaces the former fail2ban
  # jails and uses the community scenarios for scanners, probes and HTTP
  # abuse; decisions are shared with every bouncer.
  services.crowdsec = {
    enable = true;
    # proxmox-lxc.nix forces networking.hostName to "" when manageHostName is
    # false, so the module's hostname default would register an unnamed LAPI
    # machine (and produce credentials without a login). Pin the name.
    name = "nixnginx";
    autoUpdateService = true;
    hub.collections = [ "crowdsecurity/nginx" ];
    # The collection install does not enable the base parsers; without these the
    # journald lines never reach nginx-logs and every line is unparsed.
    hub.parsers = [
      "crowdsecurity/syslog-logs"
      "crowdsecurity/dateparse-enrich"
      "crowdsecurity/whitelists"
    ];
    settings.general.api.server.enable = true;
    settings.general.api.server.listen_uri = "0.0.0.0:8080";
    # The NixOS module requires a credentials path when the local LAPI is
    # enabled; cscli writes the machine credentials there.
    settings.lapi.credentialsFile = "/var/lib/crowdsec/local-api-credentials";
    # Expose CrowdSec's Prometheus endpoint on the service LAN for scraping.
    settings.general.prometheus.listen_addr = "0.0.0.0";
    localConfig.acquisitions = [
      {
        source = "journalctl";
        journalctl_filter = [ "_SYSTEMD_UNIT=nginx.service" ];
        labels = { type = "nginx"; };
      }
    ];
    # Never ban the Proxmox host's own public addresses (DNAT/hairpin traffic).
    localConfig.parsers.s02Enrich = [
      {
        name = "local/whitelist-hosts";
        description = "Whitelist the Proxmox host public addresses";
        whitelist = {
          reason = "proxmox host public ip";
          cidr = [ "178.63.124.242/32" "195.201.13.200/32" ];
        };
      }
    ];
  };
  services.crowdsec-firewall-bouncer = {
    enable = true;
    # Registers the bouncer against the local CrowdSec LAPI and manages the
    # iptables/ipset rules (networking.nftables is disabled in this repo).
    registerBouncer.enable = true;
  };

  # NixOS 26.05's crowdsec module runs its two stateful units as DynamicUser
  # while sharing /var/lib/crowdsec; the second unit then cannot write the
  # first unit's machine credentials. Run both as the static crowdsec user.
  systemd.services.crowdsec.serviceConfig.DynamicUser = lib.mkForce false;
  systemd.services.crowdsec.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.DynamicUser =
    lib.mkForce false;
  systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.PrivateUsers =
    lib.mkForce false;
  systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.User =
    lib.mkForce "crowdsec";
  systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.Group =
    lib.mkForce "crowdsec";
  # The module's bouncer registration calls the raw cscli binary, which
  # defaults to /etc/crowdsec/config.yaml; expose the generated config there.
  environment.etc."crowdsec/config.yaml".source =
    (pkgs.formats.yaml { }).generate "crowdsec.yaml"
      config.services.crowdsec.settings.general;

  # Export active CrowdSec decisions (IP, reason/scenario, origin and
  # remaining duration) for the Grafana security dashboard.
  systemd.services.crowdsec-decisions-exporter = {
    description = "Export active CrowdSec decisions to Prometheus textfile";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.crowdsec pkgs.python3 pkgs.coreutils ];
    script = ''
      set -euo pipefail
      OUT=/var/lib/node-exporter-textfile/crowdsec.prom
      TMP=$(mktemp /var/lib/node-exporter-textfile/.crowdsec-prom.XXXXXX)
      trap 'rm -f "$TMP"' EXIT
      ${pkgs.crowdsec}/bin/cscli -c /etc/crowdsec/config.yaml decisions list -o json 2>/dev/null \
        | ${pkgs.python3}/bin/python3 ${../nixmonitoring/crowdsec-decisions.py} > "$TMP" || true
      if [ -s "$TMP" ]; then
        chmod 0644 "$TMP"
        mv -f "$TMP" "$OUT"
      fi
    '';
  };
  systemd.timers.crowdsec-decisions-exporter = {
    description = "Periodically export CrowdSec decisions";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/1";
      Unit = "crowdsec-decisions-exporter.service";
    };
  };

  # Networking
  networking = {
    hostName = "nixnginx";

    # Static IP Configuration matching the nixnginx server setup
    useDHCP = false;

    # Firewall; the CrowdSec firewall bouncer inserts its own INPUT chain.
    firewall = {
      enable = true;
      # 9100 is node_exporter, scraped by nixmonitoring. It is not forwarded
      # from the Proxmox host, so this only opens the service LAN.
      allowedTCPPorts = [ 80 443 8080 9100 6060 ];
      allowedUDPPorts = [ 3478 5349 ];
      allowedUDPPortRanges = [ { from = 49152; to = 65535; } { from = 40000; to = 41000; } ];
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
      10.20.20.14 livekit.minnecker.com
      fd01::14 livekit.minnecker.com
      10.20.20.14 www.minnecker.com minnecker.com
      fd01::14 www.minnecker.com minnecker.com
    '';
  };
}
