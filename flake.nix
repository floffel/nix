{
  description = "NixOS configurations for Proxmox LXC containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      mkCheck = name: path:
        let
          sys = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ path ];
          };
          toplevel = sys.config.system.build.toplevel;
        in
          builtins.seq toplevel.drvPath
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
          cfg = (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ path ];
          }).config;
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
            builtins.throw "Missing fail2ban filter definitions for ${name}: ${builtins.concatStringsSep ", " missing}"
          else
            pkgs.runCommand "check-fail2ban-filters-${name}" {} "touch $out";
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

        # Integrity: fail2ban filter files must exist for every jail reference
        fail2ban-filters-nixnginx = checkFail2banFilters "nixnginx" ./nixnginx/configuration.nix;
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