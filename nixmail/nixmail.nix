{ config, pkgs, lib, ... }:

let
  # parsedmarc config rendered from our own ini (the NixOS module's generated
  # ini + stock unit are unsuitable: they assume a DynamicUser and IMAP.
  # See the parsedmarc section below).
  parsedmarcIni = (pkgs.formats.ini { }).generate "parsedmarc.ini" {
    general = {
      save_aggregate = false;
      save_forensic = false;
    };
    maildir = {
      maildir_path = "/var/vmail/minnecker.com/florian/maildir/.Reports";
      create = true;
      delete = true;
    };
    smtp = {
      host = "127.0.0.1";
      port = 587;
      ssl = false;
      # parsedmarc 9.x requires both smtp.user and smtp.password keys. An empty
      # password means mailsuite skips AUTH entirely; the local reports
      # recipient passes reject_unauth_destination and is resolved by the
      # alias/catch-all maps, so the digest still goes out without credentials.
      user = "reports@minnecker.com";
      password = "";
      # The loopback submission endpoint presents the minnecker.com
      # certificate, which does not cover 127.0.0.1. Skip verification for
      # this local hop only.
      skip_certificate_verification = true;
      from = "reports@minnecker.com";
      to = "florian@minnecker.com";
    };
  };
in
{
  systemd.tmpfiles.rules = [
    "d /var/vmail 0770 dovecot dovecot - -"
  ];

  # Generate Dovecot + Postfix LDAP config files from the shared mail
  # token (provisioned by nixidm's kanidm-mail-token service on every
  # Kanidm start).  Runs before dovecot and postfix so the files exist
  # at service startup.  The token file lives on the shared NAS mount
  # and is refreshed automatically; this service just renders the
  # per-consumer config files from it.
  systemd.services.mail-ldap-config = {
    description = "Generate Dovecot/Postfix LDAP config from shared mail token";
    # NOTE: the NixOS dovecot2 module names its unit "dovecot" (not
    # "dovecot2"), see nixos/modules/services/mail/dovecot.nix.
    wantedBy = [ "dovecot.service" "postfix.service" ];
    before = [ "dovecot.service" "postfix.service" ];
    # No RemainAfterExit: the service must re-enter "inactive (dead)" after
    # running so the mail-ldap-config.path watcher can re-trigger it when the
    # shared token file rotates. Boot ordering is unaffected — `before`/`wantedBy`
    # govern the start transaction, not steady-state.
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail

      TOKEN_FILE=/var/lib/secrets/mail/ldap/ldap-token
      DEST=/var/lib/secrets/mail

      # Wait for the token file to exist (nixidm may not have run yet
      # on a fresh boot after a Kanidm DB restore)
      for i in $(seq 1 30); do
        if [ -s "$TOKEN_FILE" ]; then
          break
        fi
        echo "Waiting for mail LDAP token..."
        sleep 2
      done
      if [ ! -s "$TOKEN_FILE" ]; then
        echo "ERROR: $TOKEN_FILE not found — start nixidm first." >&2
        exit 1
      fi

      TOKEN=$(cat "$TOKEN_FILE")
      mkdir -p "$DEST/dovecot" "$DEST/postfix"

      # 1. Dovecot LDAP password file
      printf '%s' "$TOKEN" > "$DEST/dovecot/ldap-password.txt"
      chmod 644 "$DEST/dovecot/ldap-password.txt"
      if id dovecot >/dev/null 2>&1; then
        chown "$(id -u dovecot):$(id -g dovecot)" "$DEST/dovecot/ldap-password.txt"
      fi

      # 2. Postfix LDAP query configuration files
      write_cf() {
        local name="$1" filter="$2" attr="$3" format="$4"
        {
          echo "server_host = ldaps://ldap:636"
          echo "search_base = dc=minnecker,dc=com"
          echo "query_filter = $filter"
          echo "result_attribute = $attr"
          [ -n "$format" ] && [ "$format" != "-" ] && echo "result_format = $format"
          echo "bind = yes"
          echo "bind_dn = dn=token"
          echo "bind_pw = $TOKEN"
          echo "version = 3"
          echo "tls_require_cert = no"
        } > "$DEST/postfix/$name"
        chmod 644 "$DEST/postfix/$name"
      }

      write_cf ldap-recipients.cf  '(&(mail=%s)(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))' mail -
      write_cf ldap-aliases.cf     '(&(mail=%s)(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))' uid '%s@minnecker.com'
      write_cf ldap-senders.cf      '(&(mail=%s)(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))' uid -
      # Escape the asterisk: an LDAP filter value of *@domain is a wildcard
      # that matches every mail_users member, so any unknown recipient would
      # resolve to all users. \2a matches the literal catch-all alias address
      # (*@domain) that an operator sets explicitly on one Kanidm account.
      write_cf ldap-catchalls.cf   '(&(mail=\2a@%d)(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))' uid '%s@minnecker.com'
      write_cf ldap-domains.cf      '(mail=*@%s)' mail -

      if id postfix >/dev/null 2>&1; then
        chown -R "$(id -u postfix):$(id -g postfix)" "$DEST/postfix"
      fi

      echo "Dovecot/Postfix LDAP configs generated."
    '';
  };

  # The mail LDAP token is regenerated by nixidm's kanidm-mail-token service
  # on every Kanidm (re)start (so it is always signed by the current key
  # set, which is invalidated on a DB restore). The old token is destroyed
  # in the process, so any consumer still holding the previous token keeps
  # binding fine (the JWS signature stays valid and the token's own expiry
  # is None) but every search fails with "The token grace window has
  # passed ... SessionExpired" — the ApiTokenSession was removed from the
  # account entry.
  #
  # mail-ldap-config above only runs once at boot, so without a watcher
  # nixmail keeps presenting the destroyed token after every kanidm
  # restart. This path unit re-triggers the render + reloads the consumers
  # whenever the shared token file changes on the NAS mount, keeping the
  # baked-in bind credentials in sync.
  systemd.paths.mail-ldap-config = {
    description = "Watch the shared mail LDAP token for rotation";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/var/lib/secrets/mail/ldap/ldap-token";
      Unit = "mail-ldap-config.service";
    };
  };

  # Re-rendering the .cf / password files is not enough — Postfix and
  # Dovecot read them once at startup and cache the bind credentials and
  # long-lived LDAP connections. Reload (not restart) so they re-read config
  # and drop/re-establish pooled LDAP connections with the fresh token,
  # without dropping active SMTP/IMAP sessions. Guarded with `is-active`
  # because this service also runs once at boot, before dovecot/postfix
  # have started, where a reload call would fail the oneshot.
  systemd.services.mail-ldap-config.serviceConfig.ExecStartPost = [
    "${pkgs.bash}/bin/bash -c 'systemctl is-active --quiet postfix && ${pkgs.postfix}/bin/postfix reload || true; systemctl is-active --quiet dovecot && ${pkgs.dovecot}/bin/doveadm reload || true'"
  ];

  systemd.services.dovecot.environment = {
    LDAPTLS_REQCERT = "never";
  };

  # Postfix Configuration
  services.postfix = {
    enable = true;

    # Use module settings for main.cf
    settings = {
      main = {
        # Outbound HELO/rDNS identity: PTR for both public addresses is
        # px.minnecker.com, and px also has matching A/AAAA records. The MX
        # and client-facing name is mx.minnecker.com (same IP). Keeping the
        # HELO on px avoids an external rDNS change and gives forward-
        # confirmed reverse DNS.
        myhostname = "px.minnecker.com";
        mydomain = "minnecker.com";
        compatibility_level = "3.10";
        recipient_delimiter = "+.";
        smtpd_banner = "$myhostname ESMTP";

        local_destination_concurrency_limit = "10";
        default_destination_concurrency_limit = "20";
        inet_protocols = "all";

        # Deliver ALL mail via LMTP
        mailbox_transport = "lmtp:unix:private/dovecot-lmtp";
        virtual_transport = "lmtp:unix:private/dovecot-lmtp";

        smtpd_sasl_auth_enable = "yes";
        smtpd_sasl_local_domain = "minnecker.com";
        smtpd_sasl_type = "dovecot";
        smtpd_sasl_path = "private/auth";
        smtpd_sasl_security_options = "noanonymous";

        # Order matters: permit_auth_destination would stop evaluation for
        # every recipient in a virtual domain, making later checks
        # unreachable. reject_unauth_destination only rejects relay to
        # foreign domains and lets the remaining checks run.
        #
        # reject_unlisted_recipient is intentionally NOT used: the mail
        # domains have explicit catch-all aliases (*@domain -> florian@)
        # in Kanidm, and Postfix's unlisted check only consults
        # virtual_mailbox_maps, which would reject those addresses before
        # the catch-all alias map is reached.
        #
        # Do NOT add reject_rbl_client here: the upstream resolver returns
        # Spamhaus' 127.255.255.254 "open resolver / query refused" answer,
        # which Postfix treats as a listing (rejecting every message).
        # Rspamd's rbl module handles that return code explicitly
        # (RBL_SPAMHAUS_BLOCKED_OPENRESOLVER weight 0) and does the DNSBL
        # filtering for us.
        smtpd_recipient_restrictions = "permit_sasl_authenticated, reject_unauth_destination, reject_unknown_recipient_domain";
        smtpd_helo_restrictions = "permit_sasl_authenticated, reject_invalid_hostname, reject_unknown_hostname, reject_non_fqdn_hostname";
        smtpd_helo_required = "yes";
        biff = "no";

        virtual_alias_maps = "proxy:ldap:/var/lib/secrets/mail/postfix/ldap-aliases.cf, proxy:ldap:/var/lib/secrets/mail/postfix/ldap-catchalls.cf";
        virtual_mailbox_domains = "proxy:ldap:/var/lib/secrets/mail/postfix/ldap-domains.cf";
        virtual_mailbox_maps = "proxy:ldap:/var/lib/secrets/mail/postfix/ldap-recipients.cf";
        smtpd_sender_login_maps = "proxy:ldap:/var/lib/secrets/mail/postfix/ldap-senders.cf";
        local_recipient_maps = "$virtual_mailbox_maps";

        smtpd_milters = "inet:127.0.0.1:11332";
        non_smtpd_milters = "inet:127.0.0.1:11332";

        # A flaky/dead milter must NEVER tempfail delivery of otherwise
        # valid mail. If rspamd is slow or down, accept and deliver
        # without spam headers rather than bouncing the sender.
        milter_default_action = "accept";

        # postscreen runs on port 25 only (submission/submissions bypass it,
        # so authenticated mail is unaffected). Postfix 3.11 postscreen has
        # no built-in greylisting; the former postscreen_greylist_* options
        # were unknown parameters and silently ignored. Add postgrey/rspamd
        # greylisting separately if desired.
        # The Spamhaus site pattern deliberately matches only 127.0.0.2..11,
        # so Spamhaus' 127.255.255.254 "open resolver" answer is not a hit.
        postscreen_dnsbl_sites = "zen.spamhaus.org=127.0.0.[2..11]*3,bl.spamcop.net=127.0.0.2*2";

        smtp_tls_security_level = "may";

        # TLS certificates for direct client connections (previously
        # terminated by the nginx mail proxy on ports 465/993/587/143).
        # The same cert/key pair used by nginx and Kanidm.
        smtpd_tls_cert_file = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        smtpd_tls_key_file = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        smtpd_tls_security_level = "may";
      };

      master = {
        smtp = {
          type = "inet";
          private = false;
          chroot = false;
          maxproc = 1;
          command = "postscreen";
        };
        smtpd = {
          type = "unix";
          private = false;
          chroot = false;
          command = "smtpd";
        };
        submission = {
          type = "inet";
          private = false;
          chroot = false;
          command = "smtpd";
          args = [
            "-o" "smtpd_sasl_auth_enable=yes"
            "-o" "smtpd_sasl_type=dovecot"
            "-o" "smtpd_sasl_path=private/auth"
            "-o" "smtpd_sasl_security_options=noanonymous"
            "-o" "milter_macro_daemon_name=ORIGINATING"
          ];
        };
        # Implicit-TLS SMTPS (port 465). Previously terminated by the nginx
        # mail proxy; now exposed directly via host port forwarding. Wrapper
        # mode enables implicit TLS (no STARTTLS negotiation).
        submissions = {
          type = "inet";
          private = false;
          chroot = false;
          command = "smtpd";
          args = [
            "-o" "smtpd_tls_wrappermode=yes"
            "-o" "smtpd_sasl_auth_enable=yes"
            "-o" "smtpd_sasl_type=dovecot"
            "-o" "smtpd_sasl_path=private/auth"
            "-o" "smtpd_sasl_security_options=noanonymous"
            "-o" "milter_macro_daemon_name=ORIGINATING"
          ];
        };
      };
    };

    extraAliases = ''
      root: florian@minnecker.com
    '';
  };

  # Dovecot Configuration
  services.dovecot2 = {
    enable = true;

    settings = {
      dovecot_config_version = "2.4.4";
      dovecot_storage_version = "2.4.4";

      # TLS certificates for direct client connections (previously
      # terminated by the nginx mail proxy; now exposed directly via host
      # port forwarding).
      ssl_server_cert_file = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
      ssl_server_key_file = "/var/lib/secrets/ssl/minnecker.com/key.pem";

      auth_allow_cleartext = true;
      # Keep verbose failed-auth logging (brute-force visibility), but turn
      # off debug: the XOAUTH2 login path has been verified end-to-end, and
      # debug only adds LDAP dumps plus benign "SSL stream closed" idle
      # messages from the Kanidm userinfo HTTP client.
      auth_verbose = true;
      auth_debug = false;
      # Advertise XOAUTH2 alongside PLAIN/LOGIN. The oauth2 mechanism
      # validates Kanidm access tokens via the global oauth2 filter; PLAIN
      # falls through to the LDAP passdb (POSIX password) for legacy clients.
      auth_mechanisms = [ "plain" "login" "xoauth2" ];

      # The nginx mail proxy is removed — clients connect directly. Keep
      # PROXY protocol trust for any future HAProxy/TCP-proxy that may sit
      # in front, but it is no longer required for the auth flow.
      haproxy_trusted_networks = [ "10.20.20.14/32" "fd01::14/128" ];
      login_trusted_networks = [ "10.20.20.14/32" "fd01::14/128" ];

      lda_mailbox_autocreate = true;
      lda_mailbox_autosubscribe = true;

      mail_driver = "maildir";
      mail_uid = "dovecot";
      mail_gid = "dovecot";

      mail_home = "/var/vmail/%{user | domain | lower }/%{user}/";
      mail_path = "/var/vmail/%{user | domain | lower }/%{user | username | lower }/maildir/";

      protocols = [ "imap" "pop3" "lmtp" "sieve" ];
      recipient_delimiter = "+.";
      ssl = "yes";

      # Dovecot 2.4's lib-ldap sets LDAP_OPT_X_TLS_REQUIRE_CERT per-connection
      # based on ssl_client_require_valid_cert, overriding LDAPTLS_REQCERT.
      # Kanidm's TLS cert is for minnecker.com, not the short name 'ldap', so
      # disable cert verification for outbound LDAP connections (same as
      # Postfix's tls_require_cert=no).
      ssl_client_require_valid_cert = false;

      # OAuth2 token validation for XOAUTH2 authentication. Mail clients
      # (Thunderbird, K-9, Apple Mail, ...) that support OAuth2 obtain an
      # access token via Kanidm's browser-based authorisation code flow
      # (using the user's full Kanidm credentials, including MFA) and
      # present it to Dovecot via the XOAUTH2 SASL mechanism.
      #
      # Dovecot 2.4 changed the OAuth2 model: the XOAUTH2/OAUTHBEARER
      # mechanisms no longer use a passdb for token validation. Instead,
      # auth_sasl_oauth2_initialize() calls db_oauth2_init() against the
      # *global* auth event, reading the top-level `oauth2 { }` named
      # filter. If that filter is absent (or only nested inside a passdb),
      # introspection_mode stays empty and the auth process fatals with
      # "Cannot initialize oauth2: Missing oauth2_introspection_mode
      # setting" on startup — which surfaces as "Auth process broken" and
      # the master service throttling login attempts.
      #
      # Dovecot validates the token by calling Kanidm's OIDC userinfo
      # endpoint with the token as a Bearer header (introspection_mode =
      # auth). Kanidm returns the user's claims (sub, email, ...); Dovecot
      # extracts the `email` field as the IMAP/SMTP username and proceeds
      # with the userdb lookup below.
      #
      # This eliminates the need for a separate POSIX password for mail —
      # the user authenticates once via Kanidm SSO and the mail client
      # caches/refreshes the token automatically.
      oauth2 = {
        # Kanidm's per-client OIDC userinfo endpoint. The short name
        # `nixidm` resolves via hosts.nix (10.20.20.15). TLS cert
        # verification is disabled globally (ssl_client_require_valid_cert
        # = false) because the cert is for minnecker.com, not the short
        # hostname.
        introspection_url = "https://nixidm:8443/oauth2/openid/mail/userinfo";
        # Send the token as Authorization: Bearer (GET). Kanidm's userinfo
        # endpoint expects this — not ?access_token= (which is the default
        # tokeninfo_url mode) or POST body (RFC 7662 introspection).
        introspection_mode = "auth";
        # Extract the user's email from the userinfo response as the
        # Dovecot username. The `email` scope is granted via the scope
        # map on the `mail` OAuth2 client in kanidm.nix.
        username_attribute = "email";
      };

      # Dovecot 2.4's XOAUTH2/OAUTHBEARER mechanisms read the global
      # `oauth2 { }` filter above directly and deliberately do NOT use a
      # passdb for token validation. A `passdb oauth2` here would only add
      # the Password Grant path, which is not configured (no grant_url) and
      # makes every PLAIN/LOGIN attempt log
      # "Password grant failed: Invalid HTTP URL: Relative HTTP URL not
      # allowed" before falling through to the LDAP passdb. Leave it out.

      "passdb ldap" = {
        driver = "ldap";
        ldap_uris = "ldaps://ldap";
        ldap_auth_dn = "dn=token";
        ldap_auth_dn_password = "</var/lib/secrets/mail/dovecot/ldap-password.txt";
        ldap_base = "dc=minnecker,dc=com";
        passdb_ldap_filter = "(&(|(mail=%{user})(uid=%{user}))(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))";
        # Kanidm does NOT expose userPassword over LDAP. Password verification
        # must happen via an LDAP bind as the found user DN using their POSIX
        # password (kanidm person posix set-password). Without passdb_ldap_bind
        # Dovecot tries to read userPassword and auth always fails.
        passdb_ldap_bind = true;
      };

      "userdb ldap" = {
        driver = "ldap";
        ldap_uris = "ldaps://ldap";
        ldap_auth_dn = "dn=token";
        ldap_auth_dn_password = "</var/lib/secrets/mail/dovecot/ldap-password.txt";
        ldap_base = "dc=minnecker,dc=com";
        userdb_ldap_filter = "(&(|(mail=%{user})(uid=%{user}))(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))";
      };

      # ManageSieve master user: Roundcube's managesieve plugin cannot do
      # XOAUTH2, so it authenticates with a master password (from a shared
      # secret file) and acts as the logged-in user. The passwd file is
      # generated from the secret before dovecot starts.
      auth_master_user_separator = "*";
      "passdb master" = {
        driver = "passwd-file";
        passwd_file_path = "/run/dovecot-auth/master-users";
        master = true;
        result_success = "continue";
      };

      # Shared mailboxes (eltern@/travel@ and per-user sharing).
      "mail_plugins" = { acl = true; };
      "protocol imap" = { mail_plugins = { imap_acl = true; }; };
      acl_driver = "vfile";
      "namespace inbox" = {
        inbox = true;
        separator = "/";
        subscriptions = true;
        type = "private";
        "mailbox Drafts" = { special_use = "\\Drafts"; };
        "mailbox Junk" = { special_use = "\\Junk"; };
        "mailbox Trash" = { special_use = "\\Trash"; };
        "mailbox Sent" = { special_use = "\\Sent"; };
        "mailbox \"Sent Messages\"" = { special_use = "\\Sent"; };
      };

      "service imap-login" = {
        "inet_listener imap" = { port = 143; };
        # Listener used by the nginx mail proxy (PROXY protocol). auth.js
        # points IMAP here (port 10143); haproxy is enabled so Dovecot reads
        # the real client IP from the PROXY header sent by nginx.
        "inet_listener imap_haproxy" = { port = 10143; haproxy = true; };
      };

      "service pop3-login" = { "inet_listener pop3" = { port = 110; }; };
      "service submission-login" = { "inet_listener submission" = { port = 587; }; };
      "service managesieve-login" = { "inet_listener sieve" = { port = 4190; }; };

      "service lmtp" = {
        "unix_listener /var/lib/postfix/queue/private/dovecot-lmtp" = {
          group = "postfix"; mode = "0666"; user = "postfix";
        };
      };

      "service auth" = {
        "unix_listener /var/lib/postfix/queue/private/auth" = {
          group = "postfix"; mode = "0666"; user = "postfix";
        };
      };

      # Dovecot 2.4: `$mail_plugins` variable no longer exists (it is treated
      # as a literal plugin name, fatally breaking delivery). Plugin lists in
      # protocol sections use the attr-of-bool form instead.
      "protocol lda" = { mail_plugins = { sieve = true; }; };
      "protocol lmtp" = { mail_plugins = { sieve = true; }; };

      # Deliberately DO NOT set sieve_extensions / sieve_global_extensions:
      # setting them restricts pigeonhole to ONLY the listed extensions. In
      # 2.4 armed-with-defaults, all compiled extensions (fileinto, envelope
      # incl. :detail, mailbox, variables, ...) become available. A
      # restrictive list here is what broke the routing sieve ('unknown Sieve
      # capability fileinto', 'unknown tagged argument :detail').

      # Global BEFORE sieve: routing (quarantine, spam->Junk, reports,
      # +detail auto-folder). Order of rules matters (see routing.sieve).
      "sieve_script routing" = {
        # Dovecot 2.4 named block: the setting is sieve_script_type, not
        # `type` (which the NixOS module does not render here). Without
        # "before" the script defaults to personal and is never executed.
        sieve_script_type = "before";
        path = "/etc/dovecot/routing.sieve";
        # This setting is a DIRECTORY, not a file.
        sieve_script_bin_path = "/var/lib/dovecot/sieve-bin";
      };
      "sieve_script personal" = { active_path = "~/.dovecot.sieve"; driver = "file"; path = "~/sieve"; };
    };
  };

  # Local Redis for rspamd: scan history (WebUI graphs) + bayes/statistics.
  # Bound to loopback only; rspamd connects with no password.
  services.redis.servers.rspamd = {
    enable = true;
    bind = "127.0.0.1";
    port = 6379;
    save = [ ];
    openFirewall = false;
  };

  # Rspamd configuration using module locals
  services.rspamd = {
    enable = true;

    workers = {
      # S0: make the production milter real. Postfix sends smtpd_milters to
      # inet:127.0.0.1:11332, but the NixOS module only starts `normal` +
      # `controller` workers by default (unix socket / 11334). Without this
      # rspamd_proxy worker nothing listens on 11332 and every milter call
      # fails/times out — so X-Spam-* headers (and hence the spam sieve and
      # the quarantine flag) never appear in production. self_scan lets the
      # proxy worker reuse the local `normal` worker.
      rspamd_proxy = {
        bindSockets = lib.mkForce [ "127.0.0.1:11332" ];
        extraConfig = ''
          upstream "local" {
            default = yes;
            self_scan = yes;
          }
        '';
      };

      # Controller/WebUI reachable from the nginx proxy container
      # (10.20.20.14 / fd01::14) for rspamd.minnecker.com, in addition to
      # loopback. secure_ip + password are set in local.d/worker-controller.inc.
      controller = {
        bindSockets = lib.mkForce [ "[::]:11334" ];
      };
    };

    locals = {
      "dkim_signing.conf".text = ''
        enabled = true;
        allow_envfrom_empty = true;
        # Users authenticate as @minnecker.com but may send as an alias in
        # another hosted domain, so do not require the auth user/envelope
        # domain to match the header From domain.
        allow_hdrfrom_mismatch = true;
        allow_username_mismatch = true;
        sign_authenticated = true;
        sign_local = true;
        use_domain = "header";
        use_esld = false;
        # Never sign a domain we have no key for with the minnecker key.
        try_fallback = false;
        selector = "minnecker";
        path = "/var/lib/secrets/mail/dkim/$domain.$selector.key";
        domain {
          "minnecker.com" {
            # Dual-sign during the 2048-bit rotation: the old selector is
            # already propagated, the new one may still be in resolver caches.
            selectors [
              { path = "/var/lib/secrets/mail/dkim/minnecker.com.private"; selector = "minnecker"; }
              { path = "/var/lib/secrets/mail/dkim/minnecker.com-2048.private"; selector = "minnecker2"; }
            ];
          }
          "floffel.de" { path = "/var/lib/secrets/mail/dkim/floffel.de.private"; selector = "minnecker"; }
          "sbminnecker.de" { path = "/var/lib/secrets/mail/dkim/sbminnecker.de.private"; selector = "minnecker"; }
          "substitution.art" { path = "/var/lib/secrets/mail/dkim/substitution.art.private"; selector = "minnecker"; }
          "sbminni.de" { path = "/var/lib/secrets/mail/dkim/sbminni.de.private"; selector = "minnecker"; }
        }
      '';

      # ARC: sign with the same key under the `arc` selector so forwarded
      # mail keeps an independent auth chain.
      "arc.conf".text = ''
        enabled = true;
        # Keep ARC on the already-propagated legacy selector during the DKIM
        # rotation; move to arc2 once minnecker2 is broadly cached.
        selector = "arc";
        domain = "minnecker.com";
        path = "/var/lib/secrets/mail/dkim/minnecker.com.private";
        sign_authenticated = true;
        sign_local = true;
        allow_envfrom_empty = true;
      '';

      # Point rspamd at the local Redis for history + stats.
      "redis.conf".text = ''
        servers = "127.0.0.1:6379";
      '';
      "history_redis.conf".text = ''
        servers = "127.0.0.1:6379";
      '';

      # Score bands. add_header adds the X-Spam-* headers (drives the spam
      # sieve); reject is raised well above the quarantine band so the
      # quarantine tier (milter_headers below) catches borderline mail in a
      # mailbox instead of bouncing it. Tune after observing real scores.
      "actions.conf".text = ''
        add_header = 6;
        reject = 40;
      '';

      # Add the built-in spam header AND a custom quarantine flag header.
      # Messages scoring >= 12 (but below reject=40) get
      # X-Rspamd-Quarantine: yes, which the global routing sieve redirects to
      # the quarantine mailbox. Do NOT define a `quarantine` action here: it
      # maps to Postfix's hold queue, not a mailbox.
      "milter_headers.conf".text = ''
        use = ["spam-header"];
        extended_spam_headers = true;
        custom {
          "X-Rspamd-Quarantine" = "return function(task, common_headers) if task:get_score() >= 12 then return 'yes' end return nil end";
        }
      '';

      # Controller auth: secure_ip addresses bypass auth for reads; other
      # clients (e.g. the public internet via the LDAP-gated nginx vhost)
      # still pass the nginx LDAP check, and write operations need the
      # password anyway. Passwords are read at runtime from the rw secrets
      # mount via rspamd's $file$ directive (plaintext, provisioned by the
      # mail-rspamd-password oneshot).
      "worker-controller.inc".text = ''
        secure_ip = "127.0.0.1,10.20.20.1,fd01::1,10.20.20.14,fd01::14";
        password = "$file$/var/lib/secrets/mail/rspamd/controller-password";
        enable_password = "$file$/var/lib/secrets/mail/rspamd/controller-enable-password";
      '';

      # Allow $file$ to read the controller passwords from the rw secrets
      # mount (outside the read-only /etc/rspamd config directory).
      "options.inc".text = ''
        secure_config = false;
      '';

      # Adaptive greylisting in rspamd (Redis-backed). Authenticated and
      # local mail is never greylisted, so submission is unaffected; only
      # unknown inbound senders get the temporary 451 and retry.
      "greylist.conf".text = ''
        enabled = true;
        expire = 1d;
        timeout = 5m;
        key_prefix = "rg";
        max_data_len = 10k;
        message = "Try again later";
        symbol = "GREYLIST";
        action = "soft reject";
        check_local = false;
        check_authed = false;
      '';
    };
  };

  # Provision one 2048-bit DKIM key per hosted sending domain if missing,
  # and emit ready-to-paste DNS hint files. Idempotent; runs before rspamd
  # so every signing key exists at startup. The operator pastes the records
  # from /var/lib/secrets/mail/dkim/<domain>.dns into the zone and bumps the
  # serial (see nixnsd).
  systemd.services.mail-dkim-key = {
    description = "Provision DKIM signing keys + DNS hints for rspamd";
    wantedBy = [ "rspamd.service" ];
    before = [ "rspamd.service" ];
    serviceConfig.Type = "oneshot";
    path = with pkgs; [ openssl coreutils util-linux ];
    script = ''
      set -euo pipefail
      D=/var/lib/secrets/mail/dkim
      install -d -m 0700 -o rspamd -g rspamd "$D" 2>/dev/null || true

      gen_key() {
        local d="$1" key="$D/$1.private"
        if [ ! -s "$key" ]; then
          echo "Generating new 2048-bit DKIM key for $d..."
          runuser -u rspamd -- ${pkgs.openssl}/bin/openssl genrsa -out "$key" 2048 2>/dev/null \
            || ${pkgs.openssl}/bin/openssl genrsa -out "$key" 2048 2>/dev/null
        fi
        # The secrets mount may be root-squashed, so tolerate chgrp failure;
        # the rspamd group can read 0640 files created by the rspamd user.
        chgrp rspamd "$key" 2>/dev/null || true
        chmod 0640 "$key" 2>/dev/null || true
      }

      pubkey() {
        ${pkgs.openssl}/bin/openssl rsa -in "$D/$1.private" -pubout -outform DER 2>/dev/null \
          | base64 | tr -d '\n'
      }

      for d in minnecker.com floffel.de sbminnecker.de substitution.art sbminni.de; do
        gen_key "$d"
      done
      gen_key "minnecker.com-2048"

      PUBKEY=$(pubkey minnecker.com-2048)
      OLDPUB=$(pubkey minnecker.com)
      cat > "$D/minnecker.dns" <<EOF
; DNS hint for minnecker.com (operator pastes into the zone, then bumps serial).
; active 2048-bit rotation key
minnecker2._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=$PUBKEY" )
arc2._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=$PUBKEY" )
; legacy 1024-bit key (keep while old signatures are still verified)
minnecker._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=$OLDPUB" )
arc._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=$OLDPUB" )
EOF

      for d in floffel.de sbminnecker.de substitution.art sbminni.de; do
        PUBKEY=$(pubkey "$d")
        cat > "$D/$d.dns" <<EOF
; DNS hint for $d
minnecker._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=$PUBKEY" )
EOF
      done

      chgrp rspamd "$D"/*.dns 2>/dev/null || true
      chmod 0640 "$D"/*.dns 2>/dev/null || true
    '';
  };

  # Generate rspamd controller passwords on first boot into the rw secrets
  # mount. rspamd accepts a PLAINTEXT controller `password` (it compares
  # directly; only when the value starts with a $2$ bcrypt hash does it run
  # verify), so we store the generated plaintext and let the controller read
  # it via $file$. The operator finds/overrides the password at
  # /var/lib/secrets/mail/rspamd/controller-password (.enable- variant for
  # write ops). rspamadm pw cannot be used non-interactively here, hence the
  # plaintext approach.
  systemd.services.mail-rspamd-password = {
    description = "Provision rspamd controller passwords";
    wantedBy = [ "rspamd.service" ];
    before = [ "rspamd.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.openssl pkgs.coreutils ];
    script = ''
      set -euo pipefail
      D=/var/lib/secrets/mail/rspamd
      install -d -m 0750 -o rspamd -g rspamd "$D"
      for f in controller-password controller-enable-password; do
        if [ ! -s "$D/$f" ]; then
          openssl rand -hex 20 > "$D/$f"
        fi
        chown rspamd:rspamd "$D/$f"
        chmod 600 "$D/$f"
      done
    '';
  };


  environment.systemPackages = [ pkgs.dovecot_pigeonhole ];

  # Global BEFORE sieve. Runs for every delivered message, before the user's
  # personal script. Rule ORDER is critical:
  #   1. Mail expressly addressed to the quarantine mailbox -> Quarantine and
  #      STOP. This MUST come first: a re-submitted (redirected) quarantined
  #      message would otherwise hit rule 2 again and loop forever.
  #   2. rspamd's quarantine verdict header -> the recipient's Quarantine
  #      mailbox (filed directly; no redirect, so no re-injection loop).
  #   3. rspamd spam verdict headers -> Junk (consolidated from the previous
  #      standalone spam-global script so ordering with quarantine is
  #      deterministic).
  #   4. DMARC/TLS-RPT aggregate reports (To/Cc reports@) -> hidden .Reports
  #      mailbox that parsedmarc watches.
  #
  # NOTE: recipient-detail routing (user+tag / user.tag -> tag mailbox) is
  # done from the preserved To/Cc header, not from the envelope: pigeonhole
  # 2.4 here lacks the envelope :detail tagged argument, and Postfix's
  # alias/catch-all expansion strips the detail before LMTP.
  environment.etc."dovecot/routing.sieve".text = ''
    require ["fileinto", "mailbox", "envelope", "variables", "subaddress"];

    # 1. Mail expressly addressed to the quarantine mailbox -> Quarantine.
    # quarantine@ is an alias for florian@minnecker.com, so the final
    # envelope localpart is florian; match the original To header as well.
    if anyof (
      envelope :localpart "to" "quarantine",
      header :contains "To" "quarantine@minnecker.com"
    ) {
      fileinto :create "Quarantine";
      stop;
    }

    # 2. rspamd quarantine verdict -> the recipient's Quarantine mailbox.
    # File directly instead of redirecting to quarantine@: the live
    # pigeonhole build has no editheader extension for a loop marker, and
    # a redirect would be re-delivered with the X-Rspamd-Quarantine header
    # and loop forever.
    if header :contains "X-Rspamd-Quarantine" "yes" {
      fileinto :create "Quarantine";
      stop;
    }

    # 3. Spam verdict -> Junk.
    if anyof (
      header :contains "X-Spam-Flag" "YES",
      header :contains "X-Spam" "Yes"
    ) {
      fileinto :create "Junk";
      stop;
    }

    # 4. DMARC / TLS-RPT aggregate reports -> Reports mailbox.
    # Use the IMAP mailbox name "Reports" (no leading dot): Dovecot rejects
    # '.Reports' as an invalid Sieve mailbox name, but stores it on disk as
    # the Maildir folder .Reports, which is what parsedmarc watches.
    if anyof (
      header :contains "To" "reports@minnecker.com",
      header :contains "Cc" "reports@minnecker.com"
    ) {
      fileinto :create "Reports";
      stop;
    }

    # 5. Address tags: user+tag@ and user.tag@ -> mailbox "tag".
    # The address test's :detail (subaddress extension) is the correct Sieve
    # mechanism; envelope :detail is not supported by this pigeonhole and the
    # envelope detail is stripped by Postfix anyway. The preserved To/Cc
    # header still has the original address. Tags are restricted to
    # [A-Za-z0-9_-] so a tag cannot create a nested/special mailbox.
    # Bcc-only tags are not visible in To/Cc.
    if anyof (
      address :detail :matches "to" "?*",
      address :detail :matches "cc" "?*"
    ) {
      fileinto :create "''${1}";
      stop;
    }
  '';

  # Export Dovecot stats to Prometheus via the node_exporter textfile
  # collector (already enabled globally, directory 0755 node-exporter).
  # Runs every minute; writes dovecot.prom only on success (keeps the last
  # good file on transient failures).
  # Dovecot compiles the global routing sieve to /var/lib/dovecot/routing.svbin.
  # The NixOS module leaves /var/lib/dovecot root-owned, so the dovecot user
  # cannot write the compiled script and LMTP logs
  # "mkdir_parents_chgrp(...) failed: Permission denied" on every delivery.
  # Make the state directory writable by dovecot before the service starts.
  systemd.services.dovecot.preStart = lib.mkAfter ''
    install -d -m 0750 -o dovecot -g dovecot /var/lib/dovecot
    install -d -m 0750 -o dovecot -g dovecot /var/lib/dovecot/sieve-bin
    install -d -m 0750 -o dovecot -g dovecot /var/lib/dovecot/db
    chown -R dovecot:dovecot /var/lib/dovecot
  '';


  # Shared mailboxes via per-user Maildir symlinks. This is the documented
  # Dovecot approach and avoids the shared-namespace owner_* variables that
  # this 2.4 build does not expand. eltern@ is mounted for sabine/bodo;
  # travel@ for florian/helena. Idempotent and re-created on every boot.
  systemd.services.mail-shared-mailboxes = {
    description = "Create shared mailbox symlinks for eltern/travel";
    wantedBy = [ "multi-user.target" ];
    after = [ "dovecot.service" ];
    requires = [ "dovecot.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ dovecot coreutils ];
    script = ''
      set -euo pipefail
      for u in eltern travel sabine bodo florian helena; do
        doveadm mailbox create -u "$u@minnecker.com" INBOX 2>/dev/null || true
      done
      ln -sfn /var/vmail/minnecker.com/eltern/maildir /var/vmail/minnecker.com/sabine/maildir/.eltern
      ln -sfn /var/vmail/minnecker.com/eltern/maildir /var/vmail/minnecker.com/bodo/maildir/.eltern
      ln -sfn /var/vmail/minnecker.com/travel/maildir /var/vmail/minnecker.com/florian/maildir/.travel
      ln -sfn /var/vmail/minnecker.com/travel/maildir /var/vmail/minnecker.com/helena/maildir/.travel
    '';
  };

  # ManageSieve master user for Roundcube. The password is generated once in
  # the shared secrets tree; only the derived passwd-file is written to /run.
  # Roundcube reads the same secret from the shared mount.
  systemd.services.managesieve-master-user = {
    description = "Generate Dovecot master passwd for ManageSieve";
    wantedBy = [ "dovecot.service" ];
    before = [ "dovecot.service" ];
    serviceConfig.Type = "oneshot";
    path = with pkgs; [ openssl coreutils ];
    script = ''
      set -euo pipefail
      SECRET=/var/lib/secrets/ssl/minnecker.com/managesieve-master-password
      if [ ! -s "$SECRET" ]; then
        echo "ERROR: $SECRET is missing; generate it on the NAS with 'openssl rand -hex 32'" >&2
        exit 1
      fi
      install -d -m 0750 -o dovecot2 -g dovecot2 /run/dovecot-auth
      PW=$(cat "$SECRET")
      printf 'sieveadmin:{PLAIN}%s\n' "$PW" > /run/dovecot-auth/master-users
      chown dovecot2:dovecot2 /run/dovecot-auth/master-users
      chmod 0600 /run/dovecot-auth/master-users
    '';
  };

  systemd.services.dovecot-stats-exporter = {
    description = "Export Dovecot stats to Prometheus textfile";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.dovecot pkgs.coreutils ];
    script = ''
      set -euo pipefail
      OUT=/var/lib/node-exporter-textfile/dovecot.prom
      TMP=$(mktemp)
      # Prefer the native Prometheus format; fall back to parsing the
      # classic key=value dump.
      if ! doveadm stats dump --format prometheus > "$TMP" 2>/dev/null; then
        doveadm stats dump 2>/dev/null | awk '{gsub(/\./, "_"); printf "dovecot_%s %s\n", $1, $2}' > "$TMP" || { rm -f "$TMP"; exit 0; }
      fi
      if [ -s "$TMP" ]; then
        install -m 0644 -o node-exporter -g node-exporter "$TMP" "$OUT"
      fi
      rm -f "$TMP"
    '';
  };
  systemd.timers.dovecot-stats-exporter = {
    description = "Periodically export Dovecot stats";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/1";
      Unit = "dovecot-stats-exporter.service";
    };
  };



  # Notes: Ensure DKIM private key remains outside the Nix store at
  # /var/lib/secrets/mail/dkim/minnecker.com.private and is readable by rspamd.

  # DMARC + TLS-RPT report processing (parsedmarc).
  #
  # parsedmarc reads DMARC/TLS-RPT aggregate mail DIRECTLY FROM DISK via
  # its Maildir input — no IMAP, no POSIX password. The routing sieve
  # files report mail into the hidden ".Reports" mailbox, which Dovecot
  # stores on disk as florian's maildir subfolder:
  #
  #   /var/vmail/minnecker.com/florian/maildir/.Reports/
  #
  # parsedmarc runs as the dovecot mail user (see the systemd override
  # below) so it can read that Maildir. Reports are deleted after parsing
  # (raw aggregates aren't worth keeping once ingested). The digest is
  # sent via our own submission on loopback WITHOUT authentication
  # (the recipient is a local virtual address, so reject_unauth_destination
  # passes and the alias/catch-all maps resolve it), so there is NO
  # operator-managed secret for parsedmarc at all.
  #
  # postmaster@, reports@, quarantine@ and the *@domain catch-alls are
  # Kanidm mail attributes on florian, not Postfix aliases.
  services.parsedmarc = {
    enable = true;

    provision = {
      localMail.enable = false;
      elasticsearch = false;
      geoIp = false;
      grafana.datasource = false;
      grafana.dashboard = false;
    };

    # Config is generated from `parsedmarcIni` (top of file) and injected by
    # the overridden unit below, not from the module's settings renderer.
    settings = { };
  };

  # The stock parsedmarc NixOS module runs the service as a throwaway
  # DynamicUser and its ExecStartPre does `chown parsedmarc:parsedmarc` on the
  # generated ini — neither works here: there is no such user (DynamicUser is
  # off) and Dovecot-owned Maildirs need the dovecot user to read them.
  #
  # Replace the unit: run as the dovecot mail user (owner of /var/vmail), in
  # the host user namespace (so the dovecot UID is visible), and point it at
  # our rendererd ini. Ensure dovecot and the LDA-delivery path are up first.
  systemd.services.parsedmarc = {
    after = [ "dovecot.service" "postfix.service" ];
    serviceConfig = lib.mkForce {
      Type = "simple";
      User = "dovecot";
      Group = "dovecot";
      RuntimeDirectory = "parsedmarc";
      RuntimeDirectoryMode = "0755";
      ExecStartPre = "+${pkgs.writeShellScript "parsedmarc-pre" ''
        install -m 0640 -o dovecot -g dovecot ${parsedmarcIni} /run/parsedmarc/parsedmarc.ini
      ''}";
      ExecStart = "${pkgs.parsedmarc}/bin/parsedmarc -c /run/parsedmarc/parsedmarc.ini";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      PrivateUsers = false;
      ProtectHome = true;
      ProtectSystem = false;
    };
  };

  # parsedmarc's Maildir input is a one-shot scan (no IMAP watch), so run it
  # periodically instead of only once at boot.
  systemd.timers.parsedmarc = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # One digest per day instead of one every 5 minutes. Empty aggregate
      # reports still produce an empty attachment; if the digest is not
      # wanted at all, remove the [smtp] section from parsedmarcIni.
      OnCalendar = "*-*-* 06:00:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };
}
