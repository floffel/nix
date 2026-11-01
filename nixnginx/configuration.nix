# NixOS Server Configuration for the Nginx Reverse Proxy Container (nixnginx)
{ config, pkgs, lib, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nginx.nix
  ];

  # GnuPG for the Roundcube Enigma plugin; rspamc for markasjunk learning.
  # ipset is operational tooling: the firewall bouncer implements its bans as
  # ipset entries, and without the CLI there is no way to check whether a
  # decision actually reached the kernel (`ipset list crowdsec-blacklists-0`).
  environment.systemPackages = [ pkgs.gnupg pkgs.rspamd pkgs.ipset ];

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
    # The local agent/bouncer resolve this wildcard address to loopback; the
    # firewall below restricts external access to the bouncer hosts.
    settings.general.api.server.listen_uri = "0.0.0.0:8080";
    # The NixOS module requires a credentials path when the local LAPI is
    # enabled; cscli writes the machine credentials there.
    settings.lapi.credentialsFile = "/var/lib/crowdsec/local-api-credentials";
    # Expose CrowdSec's Prometheus endpoint on the service LAN for scraping.
    settings.general.prometheus.listen_addr = "10.20.20.14";
    localConfig.acquisitions = [
      {
        source = "journalctl";
        journalctl_filter = [ "_SYSTEMD_UNIT=nginx.service" ];
        labels = { type = "nginx"; };
      }
    ];
  };

  # Never ban the Proxmox host's own public addresses. They are static Hetzner
  # addresses and every DNAT/hairpin connection to a container arrives from one
  # of them, so banning them would take down the whole host.
  #
  # The operator's own addresses are deliberately NOT listed here: the
  # household gets a dynamic IPv4 and a renumbered IPv6 prefix, so an address
  # allowlist would rot silently and give false confidence. False positives are
  # instead handled structurally — the nginx edge limit was loosened (it was
  # the actual trigger, see nginx.nix), and the two scenarios that fire on
  # ordinary traffic got higher thresholds or lost their ban below.
  #
  # This stage file deliberately lives under environment.etc and NOT under
  # services.crowdsec.localConfig: the upstream module installs localConfig
  # stage files as tmpfiles.d `L+` entries whose names embed the derivation
  # hash, and tmpfiles never prunes them. Editing such a stage file therefore
  # leaves an orphan that re-declares the same parser name, and CrowdSec then
  # ignores one of the two at random ("multiple parsers named
  # local/whitelist-hosts"), silently reverting the change while the freshly
  # generated file still looks correct. A fixed name is replaced in place.
  environment.etc."crowdsec/parsers/s02-enrich/99-local-whitelist-hosts.yaml".source =
    (pkgs.formats.yaml { }).generate "local-whitelist-hosts.yaml" {
      name = "local/whitelist-hosts";
      description = "Whitelist the Proxmox host public addresses";
      whitelist = {
        reason = "proxmox host public ip";
        cidr = [
          # DNAT/hairpin source for every container on this host.
          "178.63.124.242/32"
          "195.201.13.200/32"
        ];
      };
    };

  # The hub's http-probing scenario bans after 10 distinct 404/403/400 paths
  # within 10 s, for the default 4 h, and its `blackhole: 5m` re-bans
  # immediately on any further hit. That is far too twitchy for a shared NAT
  # egress: a CLI or sync client that retries a handful of missing raw files
  # (this is what actually fired) took the whole household offline. Hub scenarios
  # cannot be edited in place — cscli re-creates the symlinks on every start —
  # so this is a local replacement with a higher threshold, a shorter sentence
  # and no blackhole, and the hub copy is stopped from banning further below.
  services.crowdsec.localConfig.scenarios = [
    {
      type = "leaky";
      name = "local/http-probing-relaxed";
      description = "Site scanning/probing from a single ip, relaxed for shared NAT egress";
      filter = "evt.Meta.service == 'http' && evt.Meta.http_status in ['404', '403', '400'] && evt.Parsed.static_ressource == 'false'";
      groupby = "evt.Meta.source_ip + '/' + evt.Parsed.target_fqdn";
      distinct = "evt.Meta.http_path";
      capacity = 25;
      leakspeed = "10s";
      # No `duration` here on purpose. Decision length is set by a remediation
      # profile, and this host installs none, so every ban is the LAPI default
      # of 4h — a scenario-level `duration` is silently ignored. Shortening the
      # sentence means adding services.crowdsec.localConfig.profiles.
      reprocess = true;
      labels = {
        remediation = true;
        service = "http";
        behavior = "http:scan";
        label = "HTTP Probing (relaxed)";
        confidence = 1;
        spoofable = 0;
        classification = [ "attack.T1595" ];
      };
    }
  ];

  # Stop the hub copies of the two rate-limit-shaped scenarios from banning.
  # Both measure "this client was already throttled", so they double-punish and
  # they are the two that fire on legitimate heavy clients:
  #   * nginx-req-limit-exceeded — nginx answered 429 on its own; the throttle
  #     IS the mitigation, a firewall ban on top only hits the household.
  #   * http-probing — replaced by local/http-probing-relaxed above.
  # Filtering happens in the bouncer, so the alerts are still recorded and stay
  # visible in `cscli alerts list` and Grafana; only the ban is dropped. Every
  # other scenario (sensitive files, path traversal, CVE probing, brute force,
  # bad user agents) keeps banning at the hub defaults.
  services.crowdsec-firewall-bouncer.settings.scenarios_not_containing = [
    "crowdsecurity/http-probing"
    "crowdsecurity/nginx-req-limit-exceeded"
  ];

  # Upstream sets no restart trigger that covers the generated CrowdSec config,
  # so `nixos-rebuild switch` rewrites /etc/crowdsec but leaves the running
  # agent on the old ruleset — the change looks deployed but is inert.
  systemd.services.crowdsec.restartTriggers = [
    (pkgs.writeText "crowdsec-settings" (builtins.toJSON config.services.crowdsec.settings))
    (pkgs.writeText "crowdsec-local-config" (builtins.toJSON config.services.crowdsec.localConfig))
    (pkgs.writeText "crowdsec-hub" (builtins.toJSON config.services.crowdsec.hub))
    config.environment.etc."crowdsec/parsers/s02-enrich/99-local-whitelist-hosts.yaml".source
    config.systemd.services.crowdsec-stage-prune.script
  ];
  systemd.services.crowdsec-firewall-bouncer.restartTriggers = [
    (pkgs.writeText "crowdsec-bouncer-settings"
      (builtins.toJSON config.services.crowdsec-firewall-bouncer.settings))
  ];

  # Belt and braces for the tmpfiles problem above: drop stage symlinks that
  # point into the Nix store but are no longer declared by the active tmpfiles
  # rules, i.e. orphans from an earlier generation. Hub files are skipped
  # because they resolve under /var/lib/crowdsec/state/hub, and our own
  # environment.etc entry because it resolves under /etc/static.
  #
  # This has to be its own unit: the upstream module's extraConfig carries an
  # empty `ExecStartPre=`, which resets the list and silently discards anything
  # contributed through systemd.services.crowdsec.preStart.
  systemd.services.crowdsec-stage-prune = {
    description = "Prune orphan CrowdSec stage files";
    before = [ "crowdsec.service" ];
    after = [ "local-fs.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils pkgs.gnugrep ];
    script = ''
      for link in /etc/crowdsec/parsers/*/* /etc/crowdsec/scenarios/* \
                  /etc/crowdsec/postoverflows/*/*; do
        [ -L "$link" ] || continue
        target="$(readlink "$link" || true)"
        case "$target" in /nix/store/*) ;; *) continue ;; esac
        grep -qF "$target" /etc/tmpfiles.d/*.conf 2>/dev/null && continue
        echo "pruning orphan CrowdSec stage file $link -> $target"
        rm -f "$link"
      done
    '';
  };
  # Pull the prune in on every CrowdSec start, not only at boot. Wants rather
  # than Requires, so a pruning failure can never keep the security agent down.
  systemd.services.crowdsec.wants = [ "crowdsec-stage-prune.service" ];
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
      # Public HTTP(S) only. Scrape and LAPI access is source-restricted below.
      allowedTCPPorts = [ 80 443 ];
      allowedUDPPorts = [ 3478 5349 ];
      allowedUDPPortRanges = [{ from = 49152; to = 65535; } { from = 40000; to = 41000; }];
      extraCommands = ''
        iptables -A nixos-fw -p tcp -s 10.20.20.11 --dport 8080 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp -s 10.20.20.12 --dport 8080 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp -s 10.20.20.13 --dport 8080 -j nixos-fw-accept
        ip6tables -A nixos-fw -p tcp -s fd01::11 --dport 8080 -j nixos-fw-accept
        ip6tables -A nixos-fw -p tcp -s fd01::12 --dport 8080 -j nixos-fw-accept
        ip6tables -A nixos-fw -p tcp -s fd01::13 --dport 8080 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp -s 10.20.20.23 --dport 6060 -j nixos-fw-accept
        ip6tables -A nixos-fw -p tcp -s fd01::23 --dport 6060 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp -s 10.20.20.23 --dport 9100 -j nixos-fw-accept
        ip6tables -A nixos-fw -p tcp -s fd01::23 --dport 9100 -j nixos-fw-accept
      '';
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
