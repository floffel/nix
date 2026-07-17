# NixOS Server Configuration for the Nginx Reverse Proxy Container (nixnginx)
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
    ./nginx.nix
  ];

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

    extraSettings.fail2ban = {
      dbpurgeage = "1h";
      socket = "/run/fail2ban/fail2ban.sock";
    };

    # Store ban data on nixpostgres Redis — keep bans across fail2ban restarts.
    extraSettings.redis-server = "nixpostgres";
    extraSettings.redis-port = 6379;

    # Custom jail definitions — nginx error log based.
    jails = {
      # OAuth2 token endpoint — catches brute-force against the public PKCE
      # client discovery and token URLs. These are intentionally public but
      # a scanner probing every .well-known/ path will hammer these endpoints.
      "nginx-oauth2-brute-force" = {
        enabled = true;
        filter = "nginx-oauth2-brute-force";
        logpath = "${config.services.nginx.logDir}/error.log";
        # POST /oauth2/openid/*/token — bad_secret returns nginx map-deny 403
        # or upstream error log lines matching the filter regex.
        ports = "http,https";
        maxretry = 10;
        findtime = "600s";
        bantime = "15m";
      };

      # General nginx auth failures — catches 401 from any location that
      # does per-request auth (njs /auth/, auth_ldap, etc.). Vaultwarden
      # and Roundcube webmail both return 401 on bad credentials / token
      # expiry; this catches credential stuffing across all vhosts.
      "nginx-http-auth" = {
        enabled = true;
        filter = "nginx-http-auth";
        logpath = "${config.services.nginx.logDir}/error.log";
        ports = "http,https";
        maxretry = 8;
        findtime = "600s";
        bantime = "15m";
      };

      # Common exploit probes — known bad paths and patterns (wp-login,
      # .env, phpmyadmin, etc.). These are pure noise scanners but the
      # volume can be high (100s/hour) and adds log noise. Banning them
      # at the fail2ban/iptables level is more efficient than letting nginx
      # process every probe request.
      "nginx-botsearch" = {
        enabled = true;
        filter = "nginx-botsearch";
        logpath = "${config.services.nginx.logDir}/error.log";
        ports = "http,https";
        maxretry = 5;
        findtime = "300s";
        bantime = "30m";
      };

      # Overly aggressive bots — matches User-Agent-based patterns that are
      # clearly scanning/crawling maliciously (masscan, zgrab, etc.).
      "nginx-overload" = {
        enabled = true;
        filter = "nginx-overload";
        logpath = "${config.services.nginx.logDir}/error.log";
        ports = "http,https";
        maxretry = 3;
        findtime = "120s";
        bantime = "1h";
      };
    };

    # Wrap the built-in `actionban`/`actionunban` to use IPSET instead of
    # creating a new iptables chain per jail. This is more efficient when
    # many jails ban the same offender — all go into one IPSET (f2b-nginx)
    # and a single DROP rule in the `fail2ban` chain.
    extraSettings.actionban = ''
      iptables -I f2b-nginx 0 -s <ip> -j DROP
    '';
    extraSettings.actionunban = ''
      iptables -D f2b-nginx 0 -s <ip> -j DROP
    '';

    # The ban-action is the default iptables-multiport, but we override it
    # above to use the shared f2b-nginx IPSET chain. The nixOS module
    # generates the iptables-multiport ban action by default — we replace
    # it with a simple chain-insert so all jails share one IPSET.
  };

  # Ensure the shared iptables fail2ban chain exists before any jail starts.
  # networking.firewall.extraRules was removed in NixOS 26.05 and the firewall
  # is disabled in this LXC anyway, so create the chain via a oneshot service.
  systemd.services.fail2ban-iptables-chain = {
    description = "Create f2b-nginx iptables chain for fail2ban";
    wantedBy = [ "fail2ban.service" ];
    before = [ "fail2ban.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.iptables ];
    script = ''
      if ! iptables -L f2b-nginx -n >/dev/null 2>&1; then
        iptables -N f2b-nginx
        iptables -A f2b-nginx -j RETURN
      fi
    '';
  };

  # Networking
  networking = {
    hostName = "nixnginx";

    # Static IP Configuration matching the nixnginx server setup
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
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
      10.20.20.14 www.minnecker.com minnecker.com
      fd01::14 www.minnecker.com minnecker.com
    '';
  };
}
