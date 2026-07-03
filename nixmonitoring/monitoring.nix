# NixOS Service Configuration for Loki, Prometheus, and Grafana
{ config, pkgs, ... }:

{
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
        # Grafana runs behind the nixnginx reverse proxy, reached over
        # loopback. Trust the forwarded client-IP headers it sends so Grafana
        # logs and rate-limits by the real client IP instead of 127.0.0.1.
        # Without trusted_proxies Grafana ignores X-Real-IP/X-Forwarded-For.
        trusted_proxies = [ "127.0.0.1" "::1" ];
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
