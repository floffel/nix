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
  ];
  systemd.services.phpfpm-roundcube.path = [ pkgs.gnupg ];

  # Fail2ban — brute-force and scan protection in front of all public vhosts.
  # Jails monitor nginx error logs for OAuth2 token abuse, general auth
  # failures, and known exploit probes. Uses iptables-multiport which works
  # inside unprivileged LXC (no new netns needed). The ban action is a simple
  # chain-insert so all jails share one IPSET chain. Fail2ban uses Redis on
  # nixpostgres for its ban database so bans survive a fail2ban restart.
  services.fail2ban = {
    enable = true;

    # Ban for 15 min after 10 failures within a 10-minute findtime.
    # Redis on nixpostgres stores the in-memory ban database so fail2ban
    # survives its own restart without losing bans (persistence = rdb on).
    bantime = "15m";
    bantime-increment = {
      enable = true;
      maxtime = "6h";
      factor = "1.5";
    };

    daemonSettings.Definition = {
      dbpurgeage = "1h";
      socket = "/run/fail2ban/fail2ban.sock";
    };

    # Custom jail definitions — nginx error log based.
    jails = {
      # Use the standard per-jail iptables-multiport action (each jail has
      # its own f2b-<jail> chain, inserted into INPUT for the jail's ports).
      # Redis on nixpostgres stores fail2ban's ban database so bans survive
      # a fail2ban restart.
      DEFAULT.settings = {
        "redis-server" = "nixpostgres";
        "redis-port" = 6379;
      };
      # OAuth2 token endpoint — catches brute-force against the public PKCE
      # client discovery and token URLs. These are intentionally public but
      # a scanner probing every .well-known/ path will hammer these endpoints.
      "nginx-oauth2-brute-force" = {
        enabled = true;
        filter = "nginx-oauth2-brute-force";
        settings = {
          logpath = "/var/log/nginx/error.log";
          port = "http,https";
          maxretry = 10;
          findtime = "600s";
          bantime = "15m";
        };
      };

      # General nginx auth failures — catches 401 from any location that
      # does per-request auth (njs /auth/, auth_ldap, etc.). Vaultwarden
      # and Roundcube webmail both return 401 on bad credentials / token
      # expiry; this catches credential stuffing across all vhosts.
      "nginx-http-auth" = {
        enabled = true;
        filter = "nginx-http-auth";
        settings = {
          logpath = "/var/log/nginx/error.log";
          port = "http,https";
          maxretry = 8;
          findtime = "600s";
          bantime = "15m";
        };
      };

      # Common exploit probes — known bad paths and patterns (wp-login,
      # .env, phpmyadmin, etc.). These are pure noise scanners but the
      # volume can be high (100s/hour) and adds log noise. Banning them
      # at the fail2ban/iptables level is more efficient than letting nginx
      # process every probe request.
      "nginx-botsearch" = {
        enabled = true;
        filter = "nginx-botsearch";
        settings = {
          logpath = "/var/log/nginx/error.log";
          port = "http,https";
          maxretry = 5;
          findtime = "300s";
          bantime = "30m";
        };
      };

      # Overly aggressive bots — matches User-Agent-based patterns that are
      # clearly scanning/crawling maliciously (masscan, zgrab, etc.).
      "nginx-overload" = {
        enabled = true;
        filter = "nginx-overload";
        settings = {
          logpath = "/var/log/nginx/error.log";
          port = "http,https";
          maxretry = 3;
          findtime = "120s";
          bantime = "1h";
        };
      };
    };
  };

  # CrowdSec: parses nginx access/error logs from journald and blocks the
  # offending source IP at the firewall. This complements fail2ban (which
  # only sees a few error-log patterns) and uses the CrowdSec community
  # scenarios for scanners, probes and HTTP abuse.
  services.crowdsec = {
    enable = true;
    hub.collections = [ "crowdsecurity/nginx" ];
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
      TMP=$(mktemp)
      ${pkgs.crowdsec}/bin/cscli -c /etc/crowdsec/config.yaml decisions list -o json 2>/dev/null \
        | ${pkgs.python3}/bin/python3 ${../nixmonitoring/crowdsec-decisions.py} > "$TMP" || true
      install -m 0644 -o node-exporter -g node-exporter "$TMP" "$OUT"
      rm -f "$TMP"
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

  environment.etc."fail2ban/filter.d/nginx-oauth2-brute-force.conf".text = ''
    [Definition]
    failregex = ^\s*\[\w+\] \d+#\d+: \*\d+ access forbidden by rule, client: <ADDR>.*request: "POST .*/(?:token|authorize|device_authorization)"
                ^\s*\[\w+\] \d+#\d+: \*\d+ auth request unexpected status: 403 while sending to client, client: <ADDR>
    ignoreregex =
    journalmatch = _SYSTEMD_UNIT=nginx.service
  '';

  environment.etc."fail2ban/filter.d/nginx-overload.conf".text = ''
    [Definition]
    failregex = ^\s*\[\w+\] \d+#\d+: \*\d+ \w+ .*client: <HOST>, .*\(User-Agent: (?:masscan|zgrab|zgrab2|zgrab3|gobuster|nikto|dirbuster|sqlmap|wpscan|nmap|Nuclei|nessus)\)
    ignoreregex =
    journalmatch = _SYSTEMD_UNIT=nginx.service
  '';

  # Networking
  networking = {
    hostName = "nixnginx";

    # Static IP Configuration matching the nixnginx server setup
    useDHCP = false;

    # Firewall; fail2ban inserts its per-jail chains into INPUT itself.
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
