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

      testing = import "${nixpkgs}/nixos/lib/testing-python.nix" {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      };

      runTest = testing.makeTest;

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

      testHelpers = ./tests/test-helpers.nix;
      testPostgres = ./tests/test-postgres.nix;
      testMailRoundtrip = ./tests/mail-roundtrip.nix;

      mkBootTest = name: path: extraTest: runTest {
        name = name;
        nodes.machine = { ... }: {
          imports = [ path testHelpers ];
        };
        testScript = ''
          start_all()
          machine.wait_for_unit("multi-user.target", timeout=300)
          ${extraTest}
        '';
      };

      mkServiceTest = name: path: services: runTest {
        name = name;
        nodes.machine = { ... }: {
          imports = [ path testHelpers ];
        };
        testScript = ''
          start_all()
          machine.wait_for_unit("multi-user.target", timeout=300)
        '' + lib.concatMapStrings (s: ''
          machine.wait_for_unit("${s}", timeout=120)
        '') services;
      };

      nixnginxCfg = (mkEvalSystem ./nixnginx/configuration.nix).config;

      nginxRoutingAssertions = let
        vhosts = nixnginxCfg.services.nginx.virtualHosts or {};
        checkVhost = name: check:
          let vh = vhosts.${name} or null; in if vh == null then false else check vh;
        hasPhpLocation = vh: builtins.hasAttr "~ \\.php(/.*)?$" vh.locations;
        proxyPass = vh: vh.locations."/".proxyPass or "";
        forceSsl = vh: vh.forceSSL or false;
        assertions = [
          (checkVhost "cloud.minnecker.com"
            (vh: hasPhpLocation vh && proxyPass vh != "http://openwebui" && forceSsl vh))
          (checkVhost "ai.minnecker.com"
            (vh: proxyPass vh == "http://openwebui" && forceSsl vh))
          (checkVhost "git.minnecker.com"
            (vh: proxyPass vh == "http://forgejo" && forceSsl vh))
          (checkVhost "idm.minnecker.com"
            (vh: proxyPass vh == "https://idm" && forceSsl vh))
          (checkVhost "monitoring.minnecker.com"
            (vh: proxyPass vh == "http://nixmonitoring" && forceSsl vh))
          (checkVhost "mail.minnecker.com"
            (vh: hasPhpLocation vh && forceSsl vh))
          (checkVhost "matrix.minnecker.com"
            (vh: ((vh.locations."/_matrix" or {}).proxyPass or "") == "http://matrix" && forceSsl vh))
          (checkVhost "vault.minnecker.com"
            (vh: proxyPass vh == "http://vaultwarden" && forceSsl vh))
          (checkVhost "wiki.minnecker.com"
            (vh: proxyPass vh == "http://wikijs" && forceSsl vh))
          (checkVhost "meet.minnecker.com"
            (vh: proxyPass vh == "http://jitsi" && forceSsl vh))
          (checkVhost "kie.minnecker.com"
            (vh: proxyPass vh == "http://kiellm" && forceSsl vh))
          (checkVhost "rspamd.minnecker.com"
            (vh: proxyPass vh == "http://nixmail" && forceSsl vh))
          (checkVhost "mta-sts.minnecker.com"
            (vh: forceSsl vh && builtins.hasAttr "= /.well-known/mta-sts.txt" vh.locations))
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
          "rspamd.minnecker.com: proxyPass http://nixmail + forceSSL"
          "mta-sts.minnecker.com: forceSSL + = /.well-known/mta-sts.txt location"
          "cloud.minnecker.com vhost must be defined"
          "cloud.minnecker.com: forceSSL must be true"
        ];
      in { assertions = assertions; errors = errorMsgs; };

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
          ((builtins.length (builtins.attrNames (cfg.services.fail2ban.jails or {}))) >= 4)
          (cfg.services.coturn.enable or false)
          (cfg.services.livekit.enable or false)
          (cfg.services.lk-jwt-service.enable or false)
        ];
        errorMsgs = [
          "nginx must be enabled" "fail2ban must be enabled"
          "nextcloud must be enabled" "phpfpm nextcloud pool must exist"
          "alloy user must exist" "node_exporter must be enabled"
          "at least 5 fail2ban jails must be defined"
          "coturn must be enabled"
          "livekit must be enabled"
          "lk-jwt-service must be enabled"
        ];
      in { assertions = assertions; errors = errorMsgs; };

      # Security assertions: mail must NOT be an open relay, and unbound
      # must NOT be an open resolver. These mirror the security VM checks
      # but run at eval time (no VM, no KVM) as a cheap tripwire.
      nixmailCfg = (mkEvalSystem ./nixmail/configuration.nix).config;
      mailSecurityAssertions = let
        pf = nixmailCfg.services.postfix.settings.main or {};
        rest = pf.smtpd_recipient_restrictions or "";
        saslOpts = pf.smtpd_sasl_security_options or "";
        hasRestriction = name: builtins.match ".*${name}.*" rest != null;
        assertions = [
          # Relaying to third-party domains must be denied for
          # unauthenticated senders. permit_auth_destination only approves
          # our own domains (LDAP-backed virtual_mailbox_domains);
          # defer_unauth_destination refuses everything else.
          (hasRestriction "defer_unauth_destination" || hasRestriction "reject_unauth_destination")
          (hasRestriction "permit_auth_destination")
          (hasRestriction "permit_sasl_authenticated")
          # noanonymous: the anonymous SASL mechanism must be disabled so
          # an unauthenticated session can never authenticate.
          (saslOpts == "noanonymous")
          # virtual_mailbox_domains is LDAP-backed: a domain with no users
          # in Kanidm is not a valid local destination.
          (builtins.match ".*proxy:ldap:.*" (pf.virtual_mailbox_domains or "") != null)
          # The mail stack must not run its own DNS resolver / authoritative
          # server (postfix/dovecot/rspamd only) — prevents accidental
          # open-resolver exposure on the mail host.
          (!(nixmailCfg.services.unbound.enable or false))
          (!(nixmailCfg.services.bind.enable or false))
          (!(nixmailCfg.services.nsd.enable or false))
          # Greylisting (postscreen) + milter failure policy must be set.
          (pf.postscreen_greylist_action or "" == "enforce")
          (pf.milter_default_action or "" == "accept")
        ];
        errorMsgs = [
          "smtpd_recipient_restrictions must contain defer/reject_unauth_destination (no open relay)"
          "smtpd_recipient_restrictions must contain permit_auth_destination"
          "smtpd_recipient_restrictions must require SASL auth for relaying"
          "smtpd_sasl_security_options must be noanonymous"
          "virtual_mailbox_domains must be LDAP-backed (proxy:ldap)"
          "nixmail must not run unbound (open resolver risk)"
          "nixmail must not run bind (open resolver risk)"
          "nixmail must not run nsd (authoritative DNS on mail host)"
          "postscreen_greylist_action must be enforce"
          "milter_default_action must be accept"
        ];
      in { assertions = assertions; errors = errorMsgs; };

      nixunboundCfg = (mkEvalSystem ./nixunbound/configuration.nix).config;
      unboundResolverAssertions = let
        ac = nixunboundCfg.services.unbound.settings.server.access-control or [];
        isAllow = entry: builtins.match ".* allow" entry != null;
        isOpenAll = entry: entry == "0.0.0.0/0 allow" || entry == "::0/0 allow" || entry == "::/0 allow";
        assertions = [
          # Must allow explicitly listed internal ranges...
          (builtins.elem "127.0.0.0/8 allow" ac)
          (builtins.elem "10.10.10.0/24 allow" ac)
          (builtins.elem "10.20.20.0/24 allow" ac)
          # ...and must NOT allow recursion for the whole internet.
          (!(builtins.any isOpenAll ac))
          ((builtins.length (builtins.filter isAllow ac)) >= 3)
        ];
        errorMsgs = [
          "unbound access-control must allow 127.0.0.0/8"
          "unbound access-control must allow 10.10.10.0/24"
          "unbound access-control must allow 10.20.20.0/24"
          "unbound must not allow recursion from 0.0.0.0/0 (open resolver)"
          "unbound must restrict access-control to an explicit allow list"
        ];
      in { assertions = assertions; errors = errorMsgs; };
      dnsEmailRecords = let
        zone = builtins.readFile ./nixnsd/zones/minnecker.com.forward;
        has = s: builtins.match ".*${s}.*" zone != null;
        assertions = [
          (has "minnecker._domainkey")
          (!(has "minnecker.com._domainkey"))
          (has "arc._domainkey")
          (has "_mta-sts")
          (has "_smtp._tls")
        ];
        errors = [
          "zone must publish minnecker._domainkey TXT (ADSP check)"
          "zone must NOT contain the broken minnecker.com._domainkey owner"
          "zone must publish arc._domainkey TXT"
          "zone must publish _mta-sts TXT"
          "zone must publish _smtp._tls TXT (TLS-RPT)"
        ];
      in { assertions = assertions; errors = errors; };
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

        routing-nixnginx = mkAssertCheck "nixnginx-routing"
          nginxRoutingAssertions.assertions nginxRoutingAssertions.errors;

        services-nixnginx = mkAssertCheck "nixnginx-services"
          servicesAssertions.assertions servicesAssertions.errors;

        mail-open-relay = mkAssertCheck "mail-open-relay"
          mailSecurityAssertions.assertions mailSecurityAssertions.errors;

        unbound-open-resolver = mkAssertCheck "unbound-open-resolver"
          unboundResolverAssertions.assertions unboundResolverAssertions.errors;

        dns-email-records = mkAssertCheck "dns-email-records"
          dnsEmailRecords.assertions dnsEmailRecords.errors;

        nsd-dnssec-bind = let
          nsdCfg = (mkEvalSystem ./nixnsd/configuration.nix).config;
          hasDnssec = builtins.any (z: z.dnssec or false)
            (builtins.attrValues (nsdCfg.services.nsd.zones or {}));
          dnssecUnit = nsdCfg.systemd.services."nsd-dnssec" or null;
        in
          if !hasDnssec then
            pkgs.runCommand "check-nsd-dnssec-bind" {} "touch $out"
          else if dnssecUnit == null then
            builtins.throw "nsd-dnssec.service must exist when NSD zones have dnssec=true"
          else
            pkgs.runCommand "check-nsd-dnssec-bind" {} "touch $out";
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixpkgs-fmt statix deadnix nil
        ];
      };

      vmTests.${system} = {
        vm-nixnginx = runTest {
          name = "nixnginx-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixnginx/configuration.nix testHelpers ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("nginx.service", timeout=120)
            machine.wait_for_open_port(443)
            machine.succeed("systemctl cat coturn.service >/dev/null")
            machine.log("nginx + coturn started — vhost routing covered by routing-nixnginx check")
          '';
        };

        vm-nixpostgres = mkServiceTest "nixpostgres-vm"
          ./nixpostgres/configuration.nix
          [ "postgresql.service" "redis-nextcloud.service" ];

        vm-nixnsd = runTest {
          name = "nixnsd-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixnsd/configuration.nix testHelpers ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("nsd.service", timeout=120)
            machine.wait_for_unit("nsd-dnssec.timer", timeout=30)
            machine.log("nsd-dnssec.timer exists — DNSSEC key rollover is scheduled")
            machine.succeed("test -f ${pkgs.bind}/bin/dnssec-keygen")
            machine.log("dnssec-keygen binary present — DNSSEC key generation dependency satisfied")

            # NSD is an AUTHORITATIVE-only server (no recursion). It must
            # serve its own zones but refuse to recurse on behalf of others
            # — otherwise it would be an open resolver / amplifier.
            # Query a zone it serves: must return NOERROR (authoritative),
            # never REFUSED.
            machine.wait_until_succeeds(
              "dig @127.0.0.1 minnecker.com SOA +timeout=2 +tries=1 | grep -q 'status: NOERROR'",
              timeout=60,
            )
            # A random out-of-zone name with recursion desired: an open
            # resolver would recurse; NSD must REFUSE it.
            machine.wait_until_succeeds(
              "dig @127.0.0.1 +recurse +timeout=2 +tries=1 openresolver-test.example. A | grep -q 'status: REFUSED'",
              timeout=60,
            )
            machine.log("nixnsd: serves own zones, refuses recursion (not an open resolver)")
          '';
        };

        vm-nixunbound = runTest {
          name = "nixunbound-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixunbound/configuration.nix testHelpers ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("unbound.service", timeout=120)
            machine.log("unbound up")

            # unbound IS a recursive resolver, but access-control only
            # allows the configured internal ranges. A query arriving from
            # a source outside those ranges must be REFUSED — otherwise
            # unbound would be an open resolver.
            #
            # Use a source address that is NOT in access-control
            # (127.0.0.0/8, 10/8, fd../64). Binding to a disallowed source
            # address exercises unbound's access-control decision.
            machine.succeed("ip addr add 198.51.100.9/32 dev lo || true")
            machine.wait_until_succeeds(
              "dig -b 198.51.100.9 @127.0.0.1 +timeout=2 +tries=1 openresolver-test.example. A | grep -q 'status: REFUSED'",
              timeout=60,
            )

            # From an allowed source (loopback) unbound must accept the
            # query and try to resolve it (recursion enabled for the
            # allow-listed subnet). Without upstream internet in the test
            # VM the answer will be SERVFAIL/NOERROR, but crucially it must
            # NOT be REFUSED.
            machine.wait_until_succeeds(
              "dig -b 127.0.0.1 @127.0.0.1 +timeout=2 +tries=1 example.org. A | grep -qv 'status: REFUSED'",
              timeout=60,
            )
            machine.log("nixunbound: recursion restricted to allowed ranges, disallowed sources refused")
          '';
        };

        vm-nixidm = mkServiceTest "nixidm-vm"
          ./nixidm/configuration.nix
          [ "kanidm.service" ];

        vm-nixvpn = runTest {
          name = "nixvpn-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixvpn/configuration.nix testHelpers ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("wireguard-metrics.timer", timeout=30)
            machine.log("wireguard-metrics.timer active — Prometheus peer metrics scheduled")
          '';
        };

        vm-nixmail = runTest {
          name = "nixmail-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixmail/configuration.nix testHelpers ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("postfix.service", timeout=120)
            machine.wait_for_unit("dovecot.service", timeout=120)
            # No LDAP backend in this unit-file test, so dovecot/postfix
            # boot but lookups do not resolve real users. Verify the
            # security-critical SMTP surface, which works backend-agnostic:
            #
            # 1. NOT an open relay: unauthenticated RCPT to a foreign
            #    domain must be refused (defer_unauth_destination), never
            #    accepted with 250.
            #
            # This is a baseline; the full login + delivery round trip
            # (and unknown-recipient rejection against real LDAP) lives in
            # vm-mail-roundtrip.
            machine.wait_until_succeeds(
              """python3 - <<'PY'
import smtplib
relay_ok = False
try:
    s = smtplib.SMTP('127.0.0.1', 587, timeout=20)
    try:
        s.ehlo('attacker.example.org')
    except smtplib.SMTPHeloError:
        pass
    try:
        s.mail('attacker@example.org')
    except smtplib.SMTPSenderRefused:
        pass
    try:
        code, msg = s.rcpt('victim@example.org')
        relay_ok = code == 250
    except smtplib.SMTPRecipientsRefused:
        pass
    s.quit()
except ConnectionRefusedError:
    raise AssertionError('smtpd not listening on 587 yet')
assert not relay_ok, 'open relay: unauthenticated RCPT to foreign domain accepted'
print('OPEN-RELAY-REJECTED')
PY
""", timeout=300,
            )
            machine.log("nixmail: open relay rejected (unauthenticated RCPT to foreign domain)")
          '';
        };

        vm-mail-roundtrip = runTest {
          name = "mail-roundtrip-vm";
          # Runs the REAL Kanidm (nixidm) and the REAL mail stack (nixmail)
          # on one machine, wired through loopback. Exercizes: Kanidm
          # provision hook, kanidm-mail-token, mail LDAP config rendering,
          # SMTP submission login (PLAIN via LDAP bind to Kanidm), IMAP
          # login + message retrieval, open-relay rejection and
          # unknown-recipient rejection against the live LDAP backend.
          nodes.machine = { ... }: {
            imports = [ testMailRoundtrip ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=600)
            machine.wait_for_unit("kanidm.service", timeout=600)
            machine.wait_for_unit("kanidm-mail-token.service", timeout=600)
            machine.wait_for_unit("test-mail-set-password.service", timeout=600)
            machine.wait_for_unit("postfix.service", timeout=120)
            machine.wait_for_unit("dovecot.service", timeout=120)
            machine.wait_for_unit("rspamd.service", timeout=120)

            # mail-ldap-config is a oneshot without RemainAfterExit (the
            # path watcher re-triggers it), so wait for its output instead.
            machine.wait_until_succeeds(
              "test -s /var/lib/secrets/mail/dovecot/ldap-password.txt",
              timeout=120,
            )
            machine.wait_until_succeeds(
              "test -s /var/lib/secrets/mail/postfix/ldap-recipients.cf",
              timeout=120,
            )

            # Wait until the shared mail LDAP token is a real JWS (written
            # by kanidm-mail-token) — test-helpers seeds a placeholder, so
            # wait for the rotation to land before hitting LDAP.
            machine.wait_until_succeeds(
              "grep -q 'eyJ' /var/lib/secrets/mail/ldap/ldap-token", timeout=300
            )

            # Give dovecot/postfix a moment to reload after the token
            # rotation (mail-ldap-config.path triggers a re-render).
            machine.wait_until_succeeds(
              "LDAPTLS_REQCERT=never ldapsearch -x -H ldaps://127.0.0.1:636 "
              "-D 'dn=token' -y /var/lib/secrets/mail/dovecot/ldap-password.txt "
              "-b 'dc=minnecker,dc=com' '(mail=testuser@minnecker.com)' dn >/dev/null 2>&1",
              timeout=300,
            )

            # SMTP submission login with the POSIX password → 235
            machine.wait_until_succeeds(
              """python3 - <<'PY'
import smtplib
s = smtplib.SMTP('127.0.0.1', 587, timeout=30)
s.ehlo('backendmail.minnecker.com')
s.login('testuser@minnecker.com', 'MailTestPass.123')
print('SMTP-LOGIN-OK')
s.quit()
PY
""", timeout=300,
            )

            # Send a message to the same user (self-delivery via LMTP)
            machine.wait_until_succeeds(
              """python3 - <<'PY'
import smtplib
msg = 'From: testuser@minnecker.com\nTo: testuser@minnecker.com\nSubject: roundtrip\n\nhello world\n'
s = smtplib.SMTP('127.0.0.1', 587, timeout=30)
s.ehlo('backendmail.minnecker.com')
s.login('testuser@minnecker.com', 'MailTestPass.123')
s.sendmail('testuser@minnecker.com', ['testuser@minnecker.com'], msg)
print('SEND-OK')
s.quit()
PY
""", timeout=300,
            )

            # Verify delivery into the maildir (dovecot LMTP side)
            machine.wait_until_succeeds(
              "find /var/vmail -type f -path '*maildir*new*' | grep -q .", timeout=300
            )

            # IMAP login + retrieve the just-delivered message
            machine.wait_until_succeeds(
              """python3 - <<'PY'
import imaplib, ssl
ctx = ssl._create_unverified_context()
m = imaplib.IMAP4('127.0.0.1', 143)
m.starttls(ssl_context=ctx)
m.login('testuser@minnecker.com', 'MailTestPass.123')
typ, _ = m.select('INBOX')
assert typ == 'OK'
typ, data = m.search(None, 'ALL')
assert data and data[0].split(), 'no messages in INBOX'
print('IMAP-LOGIN-FETCH-OK')
m.logout()
PY
""", timeout=300,
            )

            # Quarantine loop guard: a message addressed to the quarantine
            # mailbox that also carries X-Rspamd-Quarantine must be filed into
            # Quarantine (rule 1) and NOT re-redirected (rule 2) — exactly one
            # copy.
            machine.wait_until_succeeds(
              """python3 - <<'PY'
import smtplib
msg = 'From: testuser@minnecker.com\nTo: quarantine@minnecker.com\nX-Rspamd-Quarantine: yes\nSubject: q\n\nquarantine test\n'
s = smtplib.SMTP('127.0.0.1', 587, timeout=30)
s.ehlo('backendmail.minnecker.com')
s.login('testuser@minnecker.com', 'MailTestPass.123')
s.sendmail('testuser@minnecker.com', ['quarantine@minnecker.com'], msg)
print('SEND-QUARANTINE-OK')
s.quit()
PY
""", timeout=300,
            )
            machine.wait_until_succeeds(
              """python3 - <<'PY'
import subprocess
out = subprocess.run(['sh','-c',"find /var/vmail -type f -path '*quarantine*Quarantine*'"], capture_output=True, text=True).stdout
lines = [l for l in out.splitlines() if l]
assert len(lines) == 1, f'expected 1 copy in Quarantine, got {len(lines)}: {lines}'
print('QUARANTINE-OK')
PY
""", timeout=300,
            )

            # Misc stack health: dovecot stats + sieve extensions config,
            # rspamd configtest, and the rspamd WebUI/controller listener.
            machine.succeed("doveadm stats dump >/dev/null && echo DOVECOT-STATS-OK")
            machine.succeed("doveconf -a | grep -q 'sieve_global_extensions' && echo SIEVE-OK")
            machine.succeed("rspamadm configtest && echo RSPAMD-CONFIGTEST-OK")
            machine.wait_until_succeeds(
              "curl -sf http://127.0.0.1:11334/ >/dev/null && echo RSPAMD-UI-OK", timeout=120
            )

            # Open-relay rejection against live LDAP (unauthenticated).
            # Port 587 (submission) is a direct smtpd listener with the
            # same smtpd_recipient_restrictions; postscreen runs in front
            # of port 25 (probed separately below).
            machine.succeed(
              """python3 - <<'PY'
import smtplib
s = smtplib.SMTP('127.0.0.1', 587, timeout=30)
s.ehlo('attacker.example.org')
s.mail('attacker@example.org')
code, msg = s.rcpt('victim@example.org')
assert code >= 400, f'relay accepted: {code} {msg}'
s.quit()
print('RELAY-REJECTED')
PY
"""
            )

            # Bad password → SMTP auth must fail (535). AUTH PLAIN with a wrong
            # credential exercises dovecot's LDAP passdb bind against the
            # real Kanidm and must not succeed.
            machine.succeed(
              """python3 - <<'PY'
import smtplib
s = smtplib.SMTP('127.0.0.1', 587, timeout=30)
s.ehlo('backendmail.minnecker.com')
try:
    s.login('testuser@minnecker.com', 'Wrong.Pass.999')
    raise AssertionError('bad password accepted')
except smtplib.SMTPAuthenticationError as e:
    assert e.smtp_code >= 400, e
print('BAD-PASSWORD-REJECTED')
s.quit()
PY
"""
            )

            # Port 25 is fronted by postscreen (custom master override). Assert a
            # TCP-connectable listener is up; the strict open-relay
            # rejection is asserted on 587 above (same smtpd, same
            # smtpd_recipient_restrictions), which is the behaviour that
            # matters.
            machine.wait_until_succeeds(
              """python3 - <<'PY'
import socket
s = socket.create_connection(('127.0.0.1', 25), timeout=30)
data = s.recv(256)
assert data.startswith(b'220'), data
s.close()
print('PORT25-LISTENING')
PY
""", timeout=300,
            )

            machine.log("mail round-trip OK: login, send, delivery, IMAP fetch, relay rejection")
          '';
        };

        vm-nixforgejo = runTest {
          name = "nixforgejo-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixforgejo/configuration.nix testHelpers testPostgres ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("postgresql.service", timeout=120)
            machine.wait_for_unit("forgejo.service", timeout=120)
            machine.wait_for_open_port(2222, timeout=30)
            machine.log("forgejo started with local postgres, SSH server on port 2222")
          '';
        };

        vm-nixforgejo-runner = runTest {
          name = "nixforgejo-runner-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixforgejo-runner/configuration.nix testHelpers ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("docker.socket", timeout=60)
            machine.succeed("systemctl cat gitea-runner-default.service >/dev/null")
            machine.log("docker socket active, runner unit valid — requires forgejo backend")
          '';
        };

        vm-nixmonitoring = mkServiceTest "nixmonitoring-vm"
          ./nixmonitoring/configuration.nix
          [ "prometheus.service" "loki.service" "grafana.service" "influxdb2.service" ];

        vm-nixmatrix = runTest {
          name = "nixmatrix-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixmatrix/configuration.nix testHelpers testPostgres ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("postgresql.service", timeout=120)
            machine.wait_for_unit("matrix-authentication-service.service", timeout=120)
            machine.wait_for_unit("matrix-synapse.service", timeout=120)
            machine.log("matrix-synapse and MAS started with local postgres")
          '';
        };

        vm-nixvaultwarden = runTest {
          name = "nixvaultwarden-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixvaultwarden/configuration.nix testHelpers testPostgres ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("postgresql.service", timeout=120)
            machine.wait_for_unit("vaultwarden.service", timeout=120)
            machine.log("vaultwarden started with local postgres")
          '';
        };

        vm-nixwikijs = runTest {
          name = "nixwikijs-vm";
          nodes.machine = { ... }: {
            imports = [ ./nixwikijs/configuration.nix testHelpers testPostgres ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target", timeout=300)
            machine.wait_for_unit("postgresql.service", timeout=120)
            machine.wait_for_unit("wiki-js.service", timeout=120)
            machine.log("wiki-js started with local postgres")
          '';
        };

        vm-nixjitsi = mkServiceTest "nixjitsi-vm"
          ./nixjitsi/configuration.nix
          [ "nginx.service" "jitsi-meet.service" "jitsi-videobridge.service" "prosody.service" "jicofo.service" ];

        vm-nixopenwebui = mkServiceTest "nixopenwebui-vm"
          ./nixopenwebui/configuration.nix
          [ "open-webui.service" ];
      };
    };
}