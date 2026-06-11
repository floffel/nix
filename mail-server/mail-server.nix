{ config, pkgs, ... }:

{
  # Ensure the mail directory has correct ownership and permissions
  systemd.tmpfiles.rules = [
    "d /var/mail 0775 dovecot dovecot - -"
    "d /var/mail/user 0770 dovecot dovecot - -"
  ];

  # User and Group mapping to match the original system (ensures rsync ownership is preserved)
  users.groups = {
    mail = {
      gid = 12;
    };
    postfix = {
      gid = 73;
    };
    postdrop = {
      gid = 75;
    };
    dovecot = {
      gid = 76;
    };
    rspamd = {
      gid = 182; # Matching spamd GID from source system
    };
  };

  users.users = {
    postfix = {
      uid = 73;
      group = "postfix";
      extraGroups = [ "postdrop" "rspamd" ];
      isSystemUser = true;
    };
    dovecot = {
      uid = 76;
      group = "dovecot";
      isSystemUser = true;
    };
    rspamd = {
      uid = 182; # Matching spamd UID from source system
      group = "rspamd";
      isSystemUser = true;
    };
  };

  # Postfix Configuration
  services.postfix = {
    enable = true;
    hostname = "backendmail.minnecker.com";
    domain = "minnecker.com";
    
    # Forward system mail (root, postmaster) to your primary inbox
    aliases = ''
      postmaster: root
      abuse: postmaster
      root: florian@minnecker.com
    '';
    
    # Custom main.cf settings
    config = {
      compatibility_level = "3.10";
      recipient_delimiter = "+.";
      smtpd_banner = "$myhostname ESMTP";
      
      local_destination_concurrency_limit = "10";
      default_destination_concurrency_limit = "20";
      inet_protocols = "all";
      
      # Deliver ALL mail via LMTP (modern, fast, daemonized)
      mailbox_transport = "lmtp:unix:private/dovecot-lmtp";
      virtual_transport = "lmtp:unix:private/dovecot-lmtp";
      
      # SASL Authentication through Dovecot
      smtpd_sasl_auth_enable = "yes";
      smtpd_sasl_local_domain = "minnecker.com";
      smtpd_sasl_type = "dovecot";
      smtpd_sasl_path = "private/auth"; # relative to queue dir (/var/spool/postfix)
      smtpd_sasl_security_options = "noanonymous";
      
      # Restrictions and Anti-Spam
      smtpd_recipient_restrictions = "permit_sasl_authenticated, permit_auth_destination, defer_unauth_destination, reject_unknown_recipient_domain, smtpd_reject_unlisted_recipient";
      smtpd_helo_restrictions = "permit_sasl_authenticated, reject_invalid_hostname, reject_unknown_hostname, reject_non_fqdn_hostname";
      smtpd_helo_required = "yes";
      biff = "no";
      
      # Secure LDAP Mappings (resolved via secrets folder outside Nix store)
      virtual_alias_maps = "proxy:ldap:/var/lib/secrets/mail/postfix-ldap-aliases.cf";
      virtual_mailbox_domains = "proxy:ldap:/var/lib/secrets/mail/postfix-ldap-domains.cf";
      virtual_mailbox_maps = "proxy:ldap:/var/lib/secrets/mail/postfix-ldap-recipients.cf";
      smtpd_sender_login_maps = "proxy:ldap:/var/lib/secrets/mail/postfix-ldap-senders.cf";
      local_recipient_maps = "$virtual_mailbox_maps";
      
      # Rspamd Milter (integrated via TCP to prevent socket permission issues)
      smtpd_milters = "inet:127.0.0.1:11332";
      non_smtpd_milters = "inet:127.0.0.1:11332";
      
      # TLS settings (may be terminated by external proxy, but allowed)
      smtp_tls_security_level = "may";
    };

    # Custom master.cf settings (matching chroot=no from source Arch server)
    masterConfig = {
      # Override default SMTP to run postscreen
      smtp = {
        type = "inet";
        private = false;
        chroot = false; # Disabled to allow LDAP and local file access
        maxproc = 1;
        command = "postscreen";
      };
      smtpd = {
        type = "unix";
        private = false;
        chroot = false;
        command = "smtpd";
      };
      # Submission service on port 587
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

  # Dovecot Configuration
  services.dovecot2 = {
    enable = true;
    
    settings = {
      # General Settings
      auth_allow_cleartext = true;
      auth_mechanisms = "plain login";
      
      first_valid_uid = 76;
      last_valid_uid = 76;
      first_valid_gid = 76;
      last_valid_gid = 76;
      
      haproxy_trusted_networks = [ "172.16.16.3/24" "fd0c:dead:beef::16:3/64" ];
      login_trusted_networks = [ "172.16.16.2/24" "fd0c:dead:beef::16:2/64" ];
      
      lda_mailbox_autocreate = true;
      lda_mailbox_autosubscribe = true;
      
      # Mail location configuration
      mail_driver = "maildir";
      mail_uid = "dovecot";
      mail_gid = "dovecot";
      
      # Aligned Sieve Paths: mail_home resolves to username@domain, matching your filesystem
      mail_home = "/var/mail/user/%{user | domain | lower }/%{user}/";
      mail_path = "/var/mail/%{user | domain | lower }/%{user | username | lower }/maildir/";
      
      protocols = [ "imap" "pop3" "lmtp" "sieve" ];
      recipient_delimiter = "+.";
      ssl = "no";
      
      # Secure Authentication databases (args point to out-of-store secrets file)
      "passdb ldap" = {
        args = "/var/lib/secrets/mail/dovecot-ldap.conf.ext";
      };
      
      "userdb ldap" = {
        args = "/var/lib/secrets/mail/dovecot-ldap.conf.ext";
      };
      
      # Namespace configuration
      "namespace inbox" = {
        inbox = true;
        separator = "/";
        subscriptions = true;
        type = "private";
        "mailbox Drafts" = {
          special_use = "\\Drafts";
        };
        "mailbox Junk" = {
          special_use = "\\Junk";
        };
        "mailbox Trash" = {
          special_use = "\\Trash";
        };
        "mailbox Sent" = {
          special_use = "\\Sent";
        };
        "mailbox \"Sent Messages\"" = {
          special_use = "\\Sent";
        };
      };
      
      # Service listeners
      "service imap-login" = {
        "inet_listener imap" = {
          port = 143;
        };
        "inet_listener imap_haproxy" = {
          port = 10143;
        };
      };
      
      "service pop3-login" = {
        "inet_listener pop3" = {
          port = 110;
        };
      };
      
      "service submission-login" = {
        "inet_listener submission" = {
          port = 587;
        };
      };
      
      "service managesieve-login" = {
        "inet_listener sieve" = {
          port = 4190;
        };
      };
      
      "service lmtp" = {
        "unix_listener /var/spool/postfix/private/dovecot-lmtp" = {
          group = "postfix";
          mode = "0666";
          user = "postfix";
        };
      };
      
      "service auth" = {
        "unix_listener /var/spool/postfix/private/auth" = {
          group = "postfix";
          mode = "0666";
          user = "postfix";
        };
      };
      
      # Sieve plugins for LDA/LMTP
      "protocol lda" = {
        mail_plugins = "$mail_plugins sieve";
      };
      
      "protocol lmtp" = {
        mail_plugins = "$mail_plugins sieve";
      };
      
      "sieve_script personal" = {
        active_path = "~/.dovecot.sieve";
        driver = "file";
        path = "~/sieve";
      };
      
      # Run global spam filter sieve script before user-specific rules
      sieve_before = "/etc/dovecot/global-spam.sieve";
    };
  };

  # System Packages required by mail-server container
  environment.systemPackages = [
    pkgs.dovecot_pigeonhole
  ];


  # Rspamd Configuration (Replacing SpamAssassin + OpenDKIM)
  services.rspamd = {
    enable = true;
  };

  # Configure Rspamd DKIM module natively via environment.etc
  environment.etc."rspamd/local.d/dkim_signing.conf".text = ''
    # Enable DKIM signing using your existing private key
    selector = "minnecker.com";
    path = "/var/lib/secrets/mail/dkim/minnecker.com.private";
    allow_username_mismatch = true;
  '';

  # Write global sieve spam script to /etc/dovecot/global-spam.sieve
  environment.etc."dovecot/global-spam.sieve".text = ''
    require ["fileinto", "mailbox"];
    # If Rspamd flags the message as spam, move it directly to the Junk folder
    if header :contains "X-Spam" "Yes" {
      fileinto "Junk";
      stop;
    }
  '';
}
