{ config, pkgs, lib, ... }:

{
  # Postfix Configuration
  services.postfix = {
    enable = true;

    # Use module settings for main.cf
    settings = {
      main = {
        myhostname = "backendmail.minnecker.com";
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

        smtpd_recipient_restrictions = "permit_sasl_authenticated, permit_auth_destination, defer_unauth_destination, reject_unknown_recipient_domain, smtpd_reject_unlisted_recipient";
        smtpd_helo_restrictions = "permit_sasl_authenticated, reject_invalid_hostname, reject_unknown_hostname, reject_non_fqdn_hostname";
        smtpd_helo_required = "yes";
        biff = "no";

        virtual_alias_maps = "proxy:ldap:/var/lib/secrets/mail/postfix/ldap-aliases.cf";
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

      haproxy_trusted_networks = [ "172.16.16.3/24" "fd0c:dead:beef::16:3/64" ];
      login_trusted_networks = [ "172.16.16.2/24" "fd0c:dead:beef::16:2/64" ];

      lda_mailbox_autocreate = true;
      lda_mailbox_autosubscribe = true;

      mail_driver = "maildir";
      mail_uid = "dovecot";
      mail_gid = "dovecot";

      mail_home = "/var/mail/user/%{user | domain | lower }/%{user}/";
      mail_path = "/var/mail/maildir/%{user | domain | lower }/%{user | username | lower }/maildir/";

      protocols = [ "imap" "pop3" "lmtp" "sieve" ];
      recipient_delimiter = "+.";
      ssl = "no";

      passdb = {
        driver = "ldap";
        args = "/var/lib/secrets/mail/dovecot/ldap.conf.ext";
      };

      userdb = {
        driver = "ldap";
        args = "/var/lib/secrets/mail/dovecot/ldap.conf.ext";
      };

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
        "inet_listener imap_haproxy" = { port = 10143; };
      };

      "service pop3-login" = { "inet_listener pop3" = { port = 110; }; };
      "service submission-login" = { "inet_listener submission" = { port = 587; }; };
      "service managesieve-login" = { "inet_listener sieve" = { port = 4190; }; };

      "service lmtp" = {
        "unix_listener /var/spool/postfix/private/dovecot-lmtp" = {
          group = "postfix"; mode = "0666"; user = "postfix";
        };
      };

      "service auth" = {
        "unix_listener /var/spool/postfix/private/auth" = {
          group = "postfix"; mode = "0666"; user = "postfix";
        };
      };

      "protocol lda" = { mail_plugins = "$mail_plugins sieve"; };
      "protocol lmtp" = { mail_plugins = "$mail_plugins sieve"; };
      "sieve_script personal" = { active_path = "~/.dovecot.sieve"; driver = "file"; path = "~/sieve"; };

      sieve_before = "/etc/dovecot/global-spam.sieve";
    };
  };

  # Rspamd configuration using module locals
  services.rspamd = {
    enable = true;
    locals."dkim_signing.conf".text = ''
      selector = "minnecker";
      domain = "minnecker.com";
      path = "/var/lib/secrets/mail/dkim/minnecker.com.private";
    '';
  };


  environment.systemPackages = [ pkgs.dovecot_pigeonhole ];

  # Notes: Ensure DKIM private key remains outside the Nix store at
  # /var/lib/secrets/mail/dkim/minnecker.com.private and is readable by rspamd.
}
