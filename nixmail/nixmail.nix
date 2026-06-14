        smtpd_authorized_xclient_hosts = "10.20.20.14";

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

        smtpd_recipient_restrictions = "permit_sasl_authenticated, permit_auth_destination, defer_unauth_destination, reject_rbl_client sbl-xbl.spamhaus.org, reject_rbl_client bl.spamcop.net, reject_unknown_recipient_domain, smtpd_reject_unlisted_recipient";
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

        smtp_tls_security_level = "may";
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

      auth_allow_cleartext = true;
      auth_mechanisms = [ "plain" "login" ];

      haproxy_trusted_networks = [ "10.20.20.0/24" "fd01::/64" ];
