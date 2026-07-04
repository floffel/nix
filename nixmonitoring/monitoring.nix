# NixOS Service Configuration for Loki, Prometheus, and Grafana
{ config, pkgs, ... }:

{
  # Generate Grafana's local-only credentials (admin UI password and the
  # database secret_key) on first boot. These are write-once secrets with no
  # upstream provisioner: admin_password bootstraps the initial admin login
  # (OIDC/SSO takes over afterwards) and secret_key encrypts sensitive values
  # stored in Grafana's sqlite DB (/var/lib/grafana/grafana.db, which lives in
  # the container's persistent rootfs). Losing secret_key makes those blobs
  # undecryptable, so both files must persist — but they never need to leave
  # the container, hence no NAS mount. Idempotent: existing files are kept.
  systemd.services.grafana-secrets = {
    description = "Provision Grafana local admin password and secret key";
    wantedBy = [ "grafana.service" ];
    before = [ "grafana.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.openssl pkgs.coreutils ];
    script = ''
      d=/var/lib/secrets/grafana
      mkdir -p "$d"
      if [ ! -s "$d/admin-password" ]; then
        echo "Generating $d/admin-password"
        openssl rand -base64 24 > "$d/admin-password"
      fi
      if [ ! -s "$d/secret-key" ]; then
        echo "Generating $d/secret-key"
        openssl rand -hex 16 > "$d/secret-key"
      fi
      chown grafana:grafana "$d/admin-password" "$d/secret-key"
      chmod 600 "$d/admin-password" "$d/secret-key"
    '';
  };

  # 1. Prometheus Metrics Storage
  services.prometheus = {
    enable = true;
    port = 9090;
    
    scrapeConfigs = [
      # Scraping node_exporter on all containers for system resource metrics
      {
        job_name = "node";
        static_configs = [
          {
            targets = [
              "idm:9100"
              "nixmail:9100"
              "nixvpn:9100"
              "nixpostgres:9100"
              "forgejo:9100"
              "forgejo-runner:9100"
              "nixnginx:9100"
              "nixmonitoring:9100"
              "nixopenwebui:9100"
              "nixmatrix:9100"
              "nixvaultwarden:9100"
              "nixwikijs:9100"
              "nixjitsi:9100"
              "nixnsd:9100"
              "nixunbound:9100"
            ];
          }
        ];
      }
      # Scraping Forgejo native Prometheus metrics
      {
        job_name = "forgejo";
        static_configs = [
          {
            targets = [ "forgejo:3000" ];
          }
        ];
      }
      # Scraping PostgreSQL Prometheus metrics
      {
        job_name = "postgresql";
        static_configs = [
          {
            targets = [ "nixpostgres:9187" ];
          }
        ];
      }
    ];
  };

  # 2. Loki Log Aggregation
  services.loki = {
    enable = true;
    configFile = pkgs.writeText "loki-local-config.yaml" ''
      auth_enabled: false
      server:
        http_listen_port: 3100
        grpc_listen_port: 9096
      common:
        ring:
          instance_addr: 127.0.0.1
          kvstore:
            store: inmemory
        replication_factor: 1
        path_prefix: /var/lib/loki
      storage_config:
        filesystem:
          directory: /var/lib/loki/chunks
      schema_config:
        configs:
          - from: 2020-10-24
            store: tsdb
            object_store: filesystem
            schema: v13
            index:
              prefix: index_
              period: 24h
      limits_config:
        reject_old_samples: true
        reject_old_samples_max_age: 168h
    '';
  };

  # 3. Grafana Visualizations Server
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "::";
        http_port = 3000;
        domain = "monitoring.minnecker.com";
        root_url = "https://monitoring.minnecker.com/";
        # Grafana runs behind the nixnginx reverse proxy, reached over the
        # service LAN. Trust the forwarded client-IP headers it sends so Grafana
        # logs and rate-limits by the real client IP instead of the proxy address.
        # Without trusted_proxies Grafana ignores X-Real-IP/X-Forwarded-For.
        trusted_proxies = [ "10.20.20.14" "fd01::14" ];
      };
      # Load Grafana admin credentials and secrets dynamically from secure files at runtime
      security = {
        admin_user = "admin";
        admin_password = "$__file{/var/lib/secrets/grafana/admin-password}";
        secret_key = "$__file{/var/lib/secrets/grafana/secret-key}";
      };
      "auth.generic_oauth" = {
        enabled = true;
        name = "Kanidm SSO";
        allow_sign_up = true;
        client_id = "grafana";
        client_secret = "$__file{/var/lib/secrets/oauth2/grafana/secret}";
        scopes = "openid email profile groups";
        auth_url = "https://idm.minnecker.com/oauth2/authorise";
        token_url = "https://idm.minnecker.com/oauth2/token";
        api_url = "https://idm.minnecker.com/oauth2/openid/grafana/userinfo";
        role_attribute_path = "contains(groups, 'admin') && 'Admin' || 'Viewer'";
      };
    };

    # Declarative provisioning of Data Sources and Dashboard
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://127.0.0.1:9090";
          isDefault = true;
          uid = "prometheus";
        }
        {
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://127.0.0.1:3100";
          uid = "loki";
        }
      ];
      dashboards.settings.providers = [
        {
          name = "default";
          options.path = "/var/lib/grafana/dashboards";
        }
      ];
    };
  };

  # Link the preconfigured dashboard JSON into Grafana's dashboard directory on boot
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana/dashboards 0755 grafana grafana -"
    "L+ /var/lib/grafana/dashboards/system-mail.json - - - - ${./dashboards/system-mail.json}"
  ];
}
