# NixOS Service Configuration for the Nginx Reverse Proxy and Roundcube Webmail
{ config, pkgs, lib, ... }:

let
  nginx-auth-ldap = pkgs.stdenv.mkDerivation rec {
    pname = "nginx-auth-ldap";
    version = "241200eac8e4acae74d353291bd27f79e5ca3dc4";
    src = pkgs.fetchFromGitHub {
      owner = "kvspb";
      repo = "nginx-auth-ldap";
      rev = version;
      sha256 = "sha256-NE539zZ/OqSEZidgdPlv8rDJ6yvPyi+k4Hm5NNLpAPs=";
    };
    meta = {
      license = [ pkgs.lib.licenses.bsd2 ];
    };
  };
in
{
  # 1. Custom Nginx Service Configuration
  services.nginx = {
    enable = true;
    
    # Compile Nginx with mail proxy capabilities and custom modules
    package = (pkgs.nginx.override {
      withMail = true;
      withMailSsl = true;
      modules = [
        pkgs.nginxModules.brotli
        pkgs.nginxModules.njs
        nginx-auth-ldap
      ];
    }).overrideAttrs (oldAttrs: {
      buildInputs = oldAttrs.buildInputs ++ [ pkgs.openldap ];
    });

    # Set system-wide client max body size to allow large files in cloud/webmail
    clientMaxBodySize = "20G";

    # Common HTTP configurations loaded into Nginx http context.
    # We include ldap.conf from the secrets directory to prevent storing the LDAP bind password in the Nix store.
    commonHttpConfig = ''
      server_names_hash_bucket_size 128;
      proxy_headers_hash_max_size 1024;
      proxy_headers_hash_bucket_size 128;
      
      brotli on;
      auth_ldap_cache_enabled on;
      auth_ldap_cache_expiration_time 10000;
      auth_ldap_cache_size 1000;

      # Include LDAP configurations from a secure runtime location
      include /var/lib/secrets/nginx/ldap.conf;
    '';

    # 2. Upstream Definitions
    # Replicates the upstreams.conf from the Arch system
    upstreams = {
      forgejo.servers = { "nixforgejo:3000" = {}; };
      matrix.servers = { "172.16.16.12:8008" = {}; };
      ntfy.servers = { "172.16.16.12:2580" = {}; };
      jitsy.servers = { "10.0.40.1:8000" = {}; };
      wikijs.servers = { "172.16.16.19:3000" = {}; };
      vaultwarden.servers = { "172.16.16.18:8080" = {}; };
      ki.servers = { "192.168.1.196:8080" = {}; };
    };

    # 3. Virtual Hosts Configuration
    virtualHosts = {
      # Default catch-all site
      "default" = {
        default = true;
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
        ];
        serverName = "riese.minnecker.com _";
        root = "/usr/share/webapps/localhost/htdocs";
        extraConfig = ''
          error_page 500 502 503 504 /50x.html;
        '';
        locations."= /50x.html" = {
          root = "${pkgs.nginx}/html";
        };
      };

      # app.substitution.art
      "app.substitution.art" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/substitution.art/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/substitution.art/key.pem";
        root = "/usr/share/webapps/substitution.art/htdocs/app/web/";
        locations."/" = {
          tryFiles = "$uri $uri/ /index.html";
        };
        extraConfig = ''
          charset utf-8;
          client_max_body_size 200M;
        '';
      };

      # substitution.art / www.substitution.art
      "substitution.art" = {
        serverAliases = [ "www.substitution.art" ];
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/substitution.art/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/substitution.art/key.pem";
        root = "/usr/share/webapps/substitution.art/htdocs/www/";
        extraConfig = ''
          charset utf-8;
          client_max_body_size 200M;
        '';
      };

      # bau.minnecker.com
      "bau.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        root = "/usr/share/webapps/bau.minnecker.com/Hausbau-MinneckerWebsite";
        globalRedirect = null;
        extraConfig = ''
          charset utf-8;
          client_max_body_size 10M;
          expires 1m;
          index home.html index.html;

          add_header Referrer-Policy "no-referrer" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-Permitted-Cross-Domain-Policies "none" always;
          add_header X-XSS-Protection "1; mode=block" always;

          # gzip settings matching original configuration
          gzip on;
          gzip_vary on;
          gzip_comp_level 9;
          gzip_min_length 256;
          gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
          gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;
        '';
      };

      # cloud.minnecker.com (Nextcloud Server)
      "cloud.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        extraConfig = ''
          charset utf-8;
          expires 1m;

          add_header Referrer-Policy "no-referrer" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Download-Options "noopen" always;
          add_header X-Frame-Options "allow-from https://col.flos.dev/" always;
          add_header X-Permitted-Cross-Domain-Policies "none" always;
          add_header X-Robots-Tag "none" always;
          add_header X-XSS-Protection "1; mode=block" always;
        '';
      };

      # git.minnecker.com / git.flos.dev (Forgejo Proxy)
      "git.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "http://forgejo";
        };
        extraConfig = ''
          charset utf-8;
          client_max_body_size 4G;
        '';
      };

      # idm.minnecker.com (Kanidm SSO & Web UI)
      "idm.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "https://idm:8443";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header Host $host;
            proxy_ssl_verify off;
          '';
        };
      };

      # monitoring.minnecker.com (Grafana Dashboard)
      "monitoring.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "http://nixmonitoring:3000";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };

      # ai.minnecker.com (Open WebUI LLM Interface)
      "ai.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "http://openwebui:8080";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };

      # ki.minnecker.com (LDAP Protected Proxy)
      "ki.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "http://ki";
          proxyWebsockets = true;
          extraConfig = ''
            auth_ldap "Forbidden";
            auth_ldap_servers mail_users;
            auth_delay 1s;

            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_redirect off;
            proxy_http_version 1.1;
            proxy_buffering off;
            chunked_transfer_encoding off;
            proxy_set_header authorization "";
            proxy_set_header Authorization "";
          '';
        };
        extraConfig = ''
          charset utf-8;
          client_max_body_size 5M;
        '';
      };

      # localhost (Nginx Javascript Mail Auth Helper)
      "localhost" = {
        listen = [
          { addr = "127.0.0.1"; port = 80; }
          { addr = "[::1]"; port = 80; }
          { addr = "10.0.30.1"; port = 80; }
        ];
        extraConfig = ''
          js_import auth from ${./auth.js};
          error_log /var/log/nginx/localhost.err.log;
        '';
        locations."/hello" = {
          extraConfig = "js_content auth.hello;";
        };
        locations."/test/" = {
          extraConfig = "js_content auth.test;";
        };
        locations."/dbg_headers/" = {
          extraConfig = "js_content auth.printHeaders;";
        };
        locations."/auth/" = {
          extraConfig = "js_content auth.validate;";
        };
        locations."/ldapauth" = {
          proxyPass = "http://localhost/doldapauth";
          extraConfig = ''
            proxy_set_header Authorization "Basic $arg_auth";
            proxy_pass_header Authorization;
          '';
        };
        locations."/doldapauth" = {
          extraConfig = ''
            auth_ldap "Forbidden";
            auth_ldap_servers mail_users;
            auth_delay 10s;
            js_content auth.granted;
          '';
        };
      };

      # mail.minnecker.com (Roundcube)
      "mail.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        # Points to Roundcube files within Nix store
        root = "${config.services.roundcube.package}/public_html";
        locations."/" = {
          index = "index.php";
          extraConfig = "try_files $uri $uri/ /index.php?$args;";
        };
        locations."~ \\.php$" = {
          extraConfig = ''
            fastcgi_pass unix:${config.services.phpfpm.pools.roundcube.socket};
            fastcgi_index index.php;
            include ${config.services.nginx.package}/conf/fastcgi.conf;

            fastcgi_split_path_info ^(.+\.php)(/.*)$;
            fastcgi_param SCRIPT_FILENAME $request_filename;
            fastcgi_param PATH_INFO $fastcgi_path_info;
          '';
        };
        extraConfig = ''
          charset utf-8;
          client_max_body_size 4G;
          fastcgi_hide_header X-Powered-By;
          fastcgi_hide_header X-Frame-Options;
          add_header Content-Security-Policy "default-src *  data: blob: 'unsafe-inline' 'unsafe-eval';script-src * data: blob: 'unsafe-inline' 'unsafe-eval';connect-src * data: blob: 'unsafe-inline';img-src * data: blob: 'unsafe-inline';frame-src * data: blob: ;style-src * data: blob: 'unsafe-inline';font-src * data: blob: 'unsafe-inline';worker-src *;";
        '';
      };

      # matrix.minnecker.com (Element Web client & Matrix Synapse Reverse Proxy)
      "matrix.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        root = "/usr/share/webapps/element/";
        extraConfig = ''
          charset utf-8;
          client_max_body_size 2G;
        '';
        locations."/.well-known/matrix/server" = {
          extraConfig = "return 200 '{ \"m.server\": \"matrix.minnecker.com:443\" }';";
        };
        locations."/.well-known/matrix/client" = {
          extraConfig = ''
            return 200 '{ "m.homeserver": { "base_url": "https://matrix.minnecker.com" } }';
          '';
        };
        locations."/_matrix" = {
          proxyPass = "http://matrix";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 600;
            proxy_send_timeout 600;
          '';
        };
      };

      # vault.minnecker.com (Vaultwarden Proxy)
      "vault.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "http://vaultwarden";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $http_connection;
            proxy_redirect off;
            proxy_http_version 1.1;
            proxy_buffering off;
            chunked_transfer_encoding off;
            add_header Access-Control-Allow-Credentials true;
            add_header Referrer-Policy "same-origin";
            error_log /var/log/nginx/vaultwarden.error.log;
          '';
        };
        extraConfig = ''
          allow 192.168.1.1/16;
          deny all;
          charset utf-8;
          client_max_body_size 5M;
        '';
      };

      # wiki.minnecker.com (Wiki.js Proxy)
      "wiki.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "http://wikijs";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header X-Scheme $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_buffering off;
            error_log /var/log/nginx/wiki.error.log;
          '';
        };
        extraConfig = ''
          charset utf-8;
          client_max_body_size 500M;
        '';
      };

      # meet.minnecker.com (Jitsi Meet Proxy)
      "meet.minnecker.com" = {
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        locations."/" = {
          proxyPass = "http://172.16.16.20";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
          '';
        };
        extraConfig = ''
          charset utf-8;
          client_max_body_size 500M;
        '';
      };

      # www.minnecker.com / minnecker.com
      "www.minnecker.com" = {
        serverAliases = [ "minnecker.com" ];
        forceSSL = true;
        sslCertificate = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        sslCertificateKey = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        root = "/usr/share/webapps/www.minnecker.com";
        locations."/api/whatsapp/webhook" = {
          proxyPass = "http://192.168.1.196:8002";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_max_temp_file_size 0;
            client_max_body_size 10m;
            proxy_buffering off;
          '';
        };
        extraConfig = ''
          charset utf-8;
          client_max_body_size 100M;
          expires 1m;
          index home.html index.html;

          add_header Referrer-Policy "no-referrer" always;
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header X-Permitted-Cross-Domain-Policies "none" always;
          add_header X-XSS-Protection "1; mode=block" always;

          # gzip settings matching original configuration
          gzip on;
          gzip_vary on;
          gzip_comp_level 9;
          gzip_min_length 256;
          gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
          gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;
        '';
      };
    };

    # Append Mail Proxy block directly since standard NixOS module only natively manages HTTP/Stream contexts
    appendConfig = ''
      mail {
        server_name riese.minnecker.com;

        ssl_certificate /var/lib/secrets/ssl/minnecker.com/fullchain.pem;
        ssl_certificate_key /var/lib/secrets/ssl/minnecker.com/key.pem;

        ssl_protocols TLSv1.2;
        ssl_prefer_server_ciphers on;
        ssl_ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384";

        ssl_ecdh_curve secp521r1:secp384r1;
        ssl_dhparam /var/lib/secrets/nginx/dh.param;

        ssl_session_cache   shared:SSLMAIL:10m;
        ssl_session_timeout 10m;

        starttls off;

        auth_http localhost/auth/;
        proxy_pass_error_message on;
        error_log /var/log/nginx/mail.proxy.err.log;

        proxy on;

        server {
          server_name riese.minnecker.com;
          listen [::]:25 ipv6only=off;
          protocol smtp;
          smtp_auth none;
          smtp_capabilities "250-STARTTLS" "PIPELINING" "VRFY" "ETRN" "ENHANCEDSTATUSCODES" "8BITMIME" "DSN" "SMTPUTF8" "CHUNKING" "SIZE 53687063712";
          xclient on;
        }

        server {
          server_name riese.minnecker.com;
          listen [::]:465 ssl ipv6only=off;
          protocol smtp;
          smtp_auth none plain;
          smtp_capabilities "250-STARTTLS" "PIPELINING" "VRFY" "ETRN" "ENHANCEDSTATUSCODES" "8BITMIME" "DSN" "SMTPUTF8" "CHUNKING" "SIZE 53687063712";
          xclient on;
        }

        server {
          listen [::]:587 ipv6only=off;
          protocol smtp;
          smtp_auth plain login;
          smtp_capabilities "AUTH" "PIPELINING" "VRFY" "ETRN" "ENHANCEDSTATUSCODES" "8BITMIME" "DSN" "SMTPUTF8" "CHUNKING" "SIZE 53687063712";
          starttls only;
          xclient on;
        }

        server {
          listen [::]:143 ipv6only=off;
          listen [::]:993 ssl ipv6only=off;
          protocol imap;
          imap_auth login plain;
        }
      }
    '';
  };

  # 4. Roundcube Webmail Service Configuration
  services.roundcube = {
    enable = true;
    hostName = "mail.minnecker.com";
    configureNginx = false;
    
    # We do not run a local database, it resides on nixpostgres
    database = {
      host = "nixpostgres";
      passwordFile = "/var/lib/roundcube/pgpass";
    };

    # Inject variables dynamically at runtime from external secrets file (not in nix store)
    extraConfig = ''
      // Load database credentials from mounted secrets
      $db_password = rtrim(file_get_contents('/var/lib/secrets/nginx/roundcube-db-password.txt'));
      $config['db_dsnw'] = "pgsql://roundcube:$db_password@nixpostgres/roundcube";

      // Load session encryption key from mounted secrets
      $des_key = rtrim(file_get_contents('/var/lib/secrets/nginx/roundcube-des-key.txt'));
      $config['des_key'] = $des_key;

      $config['imap_host'] = 'nixmail:143';
      $config['smtp_host'] = 'nixmail:587';
      $config['auto_create_user'] = true;
      $config['product_name'] = 'Mail';
      $config['language'] = 'de_DE';
      $config['prefer_html'] = false;
      $config['draft_autosave'] = 60;
      $config['mime_param_folding'] = 0;
      $config['max_message_size'] = "2G";
    '';

    # Plugins used in original Roundcube installation
    plugins = [
      "additional_message_headers"
      "attachment_reminder"
      "enigma"
      "identity_select"
      "managesieve"
      "newmail_notifier"
      "show_additional_headers"
    ];
  };

  # 5. Nextcloud Service Configuration
  services.nextcloud = {
    enable = true;
    hostName = "cloud.minnecker.com";
    package = pkgs.nextcloud33;

    maxUploadSize = "6G";
    
    # We do not run a local database, it resides on nixpostgres
    database.createLocally = false;

    config = {
      dbtype = "pgsql";
      dbhost = "nixpostgres";
      dbname = "nextcloud";
      dbuser = "nextcloud";
      dbpassFile = "/var/lib/secrets/nginx/nextcloud-db-password.txt";
      adminpassFile = "/var/lib/secrets/nginx/nextcloud-admin-password.txt";
      adminuser = "admin";
    };
    
    settings = {
      overwriteprotocol = "https";
    };
    
    configureRedis = true;

    # Install the OIDC client application
    extraAppsEnable = true;
    extraApps = {
      inherit (pkgs.nextcloud33Packages.apps) user_oidc;
    };
  };

  # Auto-configure Nextcloud OIDC client registration on service start
  systemd.services.nextcloud-setup-oidc = {
    description = "Configure Nextcloud OIDC Provider";
    after = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = pkgs.writeShellScript "nextcloud-setup-oidc" ''
        occ="${config.services.nextcloud.occ}/bin/nextcloud-occ"
        
        # Ensure user_oidc app is enabled
        if ! $occ app:list | grep -q "user_oidc"; then
          $occ app:enable user_oidc || true
        fi

        # Check if the "kanidm" provider is already registered
        if ! $occ user_oidc:provider-list | grep -q "kanidm"; then
          if [ -f /var/lib/secrets/nginx/nextcloud-oauth-secret ]; then
            client_secret=$(cat /var/lib/secrets/nginx/nextcloud-oauth-secret)
            # Add provider but do not crash the service if Kanidm is temporarily unreachable
            $occ user_oidc:provider-add \
              --client-id="nextcloud" \
              --client-secret="$client_secret" \
              --discovery-url="https://idm.minnecker.com/oauth2/openid/nextcloud/.well-known/openid-configuration" \
              kanidm || echo "Warning: Failed to register Kanidm OIDC provider (is nixidm reachable?)"
          else
            echo "Warning: /var/lib/secrets/nginx/nextcloud-oauth-secret not found. Skipping OIDC registration."
          fi
        fi
      '';
    };
  };

  # Auto-generate the .pgpass file for Roundcube in its writeable StateDirectory
  # to bypass permission issues with the read-only mounted secrets directory.
  systemd.services.roundcube-setup = {
    preStart = ''
      if [ -f /var/lib/secrets/nginx/roundcube-db-password.txt ]; then
        password=$(cat /var/lib/secrets/nginx/roundcube-db-password.txt)
        echo "*:*:*:roundcube:$password" > /var/lib/roundcube/pgpass
        chmod 600 /var/lib/roundcube/pgpass
      else
        echo "Error: /var/lib/secrets/nginx/roundcube-db-password.txt not found!"
        exit 1
      fi
    '';
  };
}
