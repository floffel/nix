{
  description = "NixOS configurations for Proxmox LXC containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      mkEvalSystem = path: lib.nixosSystem {
        inherit system;
        modules = [ path ];
      };

      mkCheck = name: path:
        let
          sys = mkEvalSystem path;
          tl = sys.config.system.build.toplevel;
        in
          builtins.seq tl.drvPath
          (pkgs.runCommand "check-${name}" { } "touch $out");

      builtinFail2banFilters = [
        "sshd" "nginx-http-auth" "nginx-botsearch" "nginx-limit-req"
        "recidive" "apache-auth" "apache-badbots" "apache-noscript"
        "apache-overflows" "apache-nohome" "postfix" "dovecot"
        "proftpd" "vsftpd" "courier-auth" "courier-smtp"
        "named-refused" "mysqld-auth" "3proxy" "exim" "exim-spam"
        "lighttpd-auth" "perdition" "php-url-fopen" "postfix-rbl"
        "postfix-sasl" "pure-ftpd" "sasl" "selinux-ssh" "sendmail-auth"
        "sendmail-reject" "sieve" "solid-pop3d" "squid" "stunnel"
        "suphp" "tine20" "wuftpd" "xinetd-fail" "domino-smtp"
        "ejabberd-auth" "groupoffice" "guacamole" "haproxy-http-auth"
        "horde" "kerio" "monit" "openwebmail" "oracleims"
        "pam-generic" "pass2allow-ftp" "phpmyadmin-syslog"
        "portsentry" "sogo-auth" "squirrelmail" "uwimap" "zoneminder"
      ];

      checkFail2banFilters = name: path:
        let
          cfg = (mkEvalSystem path).config;
          jails = cfg.services.fail2ban.jails or {};
          customEtc = builtins.attrNames (cfg.environment.etc or {});
          customFilterPrefix = "fail2ban/filter.d/";

          isCustomFilter = filterName:
            builtins.elem "${customFilterPrefix}${filterName}.conf" customEtc
            || builtins.elem "${customFilterPrefix}${filterName}.local" customEtc;

          jailNames = builtins.filter (n: n != "DEFAULT") (builtins.attrNames jails);
          jailFilters = builtins.map (n: jails.${n}.filter or n) jailNames;
          missing = builtins.filter (f:
            ! (isCustomFilter f || builtins.elem f builtinFail2banFilters)
          ) jailFilters;
        in
          if missing != [] then
            builtins.throw "Missing fail2ban filter definitions for ${name}: ${lib.concatStringsSep ", " missing}"
          else
            pkgs.runCommand "check-fail2ban-filters-${name}" {} "touch $out";

      mkAssertCheck = name: assertions: errors:
        let
          passed = builtins.foldl' (acc: a: acc && a) true assertions;
        in
          if passed then
            pkgs.runCommand "assert-${name}" {} "touch $out"
          else
            let
              msgs = builtins.concatLists (builtins.genList (i:
                if builtins.elemAt assertions i then [] else
                [ "\n  ${toString (i + 1)}. ${builtins.elemAt errors i}" ]
              ) (builtins.length assertions));
            in
              builtins.throw "Config assertions failed for ${name}:${lib.concatStringsSep "" msgs}";

      nixnginxCfg = (mkEvalSystem ./nixnginx/configuration.nix).config;

      nginxRoutingAssertions = let
        vhosts = nixnginxCfg.services.nginx.virtualHosts or {};

        checkVhost = name: check:
          let vh = vhosts.${name} or null; in
          if vh == null then false else check vh;

        hasPhpLocation = vh: builtins.hasAttr "~ \\.php(/.*)?$" vh.locations;
        hasLocation = vh: builtins.hasAttr "/" vh.locations;
        proxyPass = vh: vh.locations."/".proxyPass or "";
        forceSsl = vh: vh.forceSSL or false;

        assertions = [
          (checkVhost "cloud.minnecker.com"
            (vh: hasPhpLocation vh && proxyPass vh != "http://openwebui" && forceSsl vh)
          )
          (checkVhost "ai.minnecker.com"
            (vh: proxyPass vh == "http://openwebui" && forceSsl vh)
          )
          (checkVhost "git.minnecker.com"
            (vh: proxyPass vh == "http://forgejo" && forceSsl vh)
          )
          (checkVhost "idm.minnecker.com"
            (vh: proxyPass vh == "https://idm" && forceSsl vh)
          )
          (checkVhost "monitoring.minnecker.com"
            (vh: proxyPass vh == "http://nixmonitoring" && forceSsl vh)
          )
          (checkVhost "mail.minnecker.com"
            (vh: hasPhpLocation vh && forceSsl vh)
          )
          (checkVhost "matrix.minnecker.com"
            (vh: ((vh.locations."/_matrix" or {}).proxyPass or "") == "http://matrix" && forceSsl vh)
          )
          (checkVhost "vault.minnecker.com"
            (vh: proxyPass vh == "http://vaultwarden" && forceSsl vh)
          )
          (checkVhost "wiki.minnecker.com"
            (vh: proxyPass vh == "http://wikijs" && forceSsl vh)
          )
          (checkVhost "meet.minnecker.com"
            (vh: proxyPass vh == "http://jitsi" && forceSsl vh)
          )
          (checkVhost "kie.minnecker.com"
            (vh: proxyPass vh == "http://kiellm" && forceSsl vh)
          )
          # cloud vhost must NOT default-catch (ai.minnecker.com was being served instead)
          (vhosts."cloud.minnecker.com" or {} != {})
          (vhosts."cloud.minnecker.com".forceSSL or false == true)
        ];

        errorMsgs = [
          "cloud.minnecker.com: PHP-FPM location + no proxy to openwebui + forceSSL"
          "ai.minnecker.com: proxyPass http://openwebui + forceSSL"
          "git.minnecker.com: proxyPass http://forgejo + forceSSL"
          "idm.minnecker.com: proxyPass https://idm + forceSSL"
          "monitoring.minnecker.com: proxyPass http://nixmonitoring + forceSSL"
          "mail.minnecker.com: PHP-FPM location + forceSSL"
          "matrix.minnecker.com: proxyPass http://matrix + forceSSL"
          "vault.minnecker.com: proxyPass http://vaultwarden + forceSSL"
          "wiki.minnecker.com: proxyPass http://wikijs + forceSSL"
          "meet.minnecker.com: proxyPass http://jitsi + forceSSL"
          "kie.minnecker.com: proxyPass http://kiellm + forceSSL"
          "cloud.minnecker.com vhost must be defined"
          "cloud.minnecker.com: forceSSL must be true"
        ];
      in {
        assertions = assertions;
        errors = errorMsgs;
      };

      servicesAssertions = let
        cfg = nixnginxCfg;
        assertions = [
          (cfg.services.nginx.enable or false)
          (cfg.services.fail2ban.enable or false)
          (cfg.services.nextcloud.enable or false)
          (builtins.hasAttr "nextcloud" (cfg.services.phpfpm.pools or {}))
          (builtins.any (u: (builtins.hasAttr "isSystemUser" u) && (u.name or "" == "alloy"))
            (builtins.attrValues (cfg.users.users or {})))
          ((builtins.length (builtins.attrNames (cfg.services.prometheus.exporters or {}))) >= 1)
          ((builtins.length (builtins.attrNames (cfg.services.fail2ban.jails or {}))) >= 5)
        ];
        errorMsgs = [
          "nginx must be enabled"
          "fail2ban must be enabled"
          "nextcloud must be enabled"
          "phpfpm nextcloud pool must exist"
          "alloy user (grafana alloy / loki agent) must exist"
          "node_exporter must be enabled"
          "at least 5 fail2ban jails must be defined"
        ];
      in {
        assertions = assertions;
        errors = errorMsgs;
      };
    in
    {
      checks.${system} = {
        nixnginx = mkCheck "nixnginx" ./nixnginx/configuration.nix;
        nixpostgres = mkCheck "nixpostgres" ./nixpostgres/configuration.nix;
        nixidm = mkCheck "nixidm" ./nixidm/configuration.nix;
        nixmail = mkCheck "nixmail" ./nixmail/configuration.nix;
        nixforgejo = mkCheck "nixforgejo" ./nixforgejo/configuration.nix;
        nixforgejo-runner = mkCheck "nixforgejo-runner" ./nixforgejo-runner/configuration.nix;
        nixnsd = mkCheck "nixnsd" ./nixnsd/configuration.nix;
        nixunbound = mkCheck "nixunbound" ./nixunbound/configuration.nix;
        nixmonitoring = mkCheck "nixmonitoring" ./nixmonitoring/configuration.nix;
        nixmatrix = mkCheck "nixmatrix" ./nixmatrix/configuration.nix;
        nixvaultwarden = mkCheck "nixvaultwarden" ./nixvaultwarden/configuration.nix;
        nixwikijs = mkCheck "nixwikijs" ./nixwikijs/configuration.nix;
        nixjitsi = mkCheck "nixjitsi" ./nixjitsi/configuration.nix;
        nixvpn = mkCheck "nixvpn" ./nixvpn/configuration.nix;
        nixopenwebui = mkCheck "nixopenwebui" ./nixopenwebui/configuration.nix;

        fail2ban-filters-nixnginx = checkFail2banFilters "nixnginx" ./nixnginx/configuration.nix;

        routing-nixnginx = mkAssertCheck
          "nixnginx-routing"
          nginxRoutingAssertions.assertions
          nginxRoutingAssertions.errors;

        services-nixnginx = mkAssertCheck
          "nixnginx-services"
          servicesAssertions.assertions
          servicesAssertions.errors;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixpkgs-fmt
          statix
          deadnix
          nil
        ];
      };
    };
}