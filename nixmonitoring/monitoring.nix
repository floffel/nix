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
  # the container, hence no bind mount at all. Idempotent: existing files are kept.
  systemd.services.grafana = {
    after = [ "influxdb-init.service" ];
  };

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
      chmod 644 "$d/admin-password" "$d/secret-key"
    '';
  };

  # 1. Prometheus Metrics Storage
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9090;
    # 90 days of metrics; size cap as a safety net. Increase the container
    # disk when the cap is reached (currently ~726 MB for 15 days).
    retentionTime = "90d";
    extraFlags = [ "--storage.tsdb.retention.size=10GB" ];
    # Alerting existed only as Grafana dashboards until 2026-11-26: metrics
    # were stored and read by hand, so a five hour mail/cloud/git outage
    # produced no notification. Rules live in a file so they can be read and
    # diffed on their own.
    ruleFiles = [ ./prometheus-alerts.yml ];
    alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:9093" ]; } ]; } ];

    scrapeConfigs = [
      # Scraping node_exporter on all containers for system resource metrics.
      # Hostnames must match the aliases declared in hosts.nix (the LXC
      # /etc/hosts map) — Prometheus resolves them via the container's DNS,
      # so a wrong name silently drops the target with a scrape error.
      {
        job_name = "node";
        static_configs = [
          {
            targets = [
              "nixidm:9100"
              "nixmail:9100"
              "nixwireguard:9100"
              "nixpostgres:9100"
              "nixforgejo:9100"
              "nixforgejo-runner:9100"
              "nixnginx:9100"
              "nixmonitoring:9100"
              "nixopenwebui:9100"
              "nixmatrix:9100"
              "nixvaultwarden:9100"
              "nixwikijs:9100"
              "nixjitsi:9100"
              "nixnsd:9100"
              "nixunbound:9100"
              # nixpaperless and nixjupyter both run prometheus-node-exporter
              # (common-lxc.nix enables it for every container) but were never
              # listed here, so a full disk or a failed unit on them stayed
              # invisible.
              "nixpaperless:9100"
              "nixjupyter:9100"
            ];
          }
        ];
      }
      # Scraping Forgejo native Prometheus metrics
      {
        job_name = "forgejo";
        static_configs = [
          {
            targets = [ "nixforgejo:3000" ];
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
      # CrowdSec agent/LAPI metrics (nginx for now; mail added when deployed).
      {
        job_name = "crowdsec";
        static_configs = [
          {
            targets = [ "10.20.20.14:6060" "10.20.20.13:6060" ];
          }
        ];
      }
    ];
  };

  # 1b. Alertmanager -- the only egress for alerts.
  #
  # Paging goes out-of-band to ntfy on purpose: the 2026-11-26 outage took
  # nixmail itself down, so an e-mail receiver could not have delivered the
  # page about itself, and Matrix sits on the same pool as the component that
  # failed.
  #
  # The topic lives in /var/lib/secrets/alertmanager/ntfy.env (write-once,
  # same pattern as grafana-secrets below) and is read only by the bridge
  # below, so it never appears in the world-readable Nix store. To find your
  # topic, read that file on this container and subscribe to
  # https://ntfy.sh/<topic>.
  #
  # ntfy has no Alertmanager integration: the `ntfy_configs` field an earlier
  # revision of this file used does not exist in Alertmanager 0.31.1 (amtool
  # check-config rejects it with "field ntfy_configs not found", and the binary
  # contains no ntfy receiver at all). Posting straight at ntfy does deliver,
  # but ntfy publishes the body verbatim -- a Slack payload or an Alertmanager
  # webhook body arrives as several hundred characters of JSON on a phone,
  # which was measured against ntfy.sh rather than assumed. So a small
  # formatter sits in front of it: Alertmanager uses its documented
  # webhook_configs, the bridge turns the payload into one short message with
  # a title, a priority and an emoji tag.
  systemd.services.alertmanager-secrets = {
    description = "Provision the ntfy topic used for alert paging";
    wantedBy = [ "multi-user.target" ];
    before = [ "alertmanager.service" "ntfy-bridge.service" ];
    path = [ pkgs.openssl pkgs.coreutils ];
    script = ''
      d=/var/lib/secrets/alertmanager
      mkdir -p "$d"
      if [ ! -s "$d/ntfy.env" ]; then
        echo "Generating $d/ntfy.env"
        printf 'NTFY_TOPIC=%s\n' "$(openssl rand -hex 16)" > "$d/ntfy.env"
      fi
      # root-only: systemd reads EnvironmentFile= as root before it drops
      # privileges, so the dynamic alertmanager user never needs read access
      # and the topic never appears in the world-readable Nix store.
      chown root:root "$d/ntfy.env"
      chmod 600 "$d/ntfy.env"
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Alertmanager has to be able to reach the bridge, otherwise the first
  # alerts after a boot are dropped with "connection refused".
  systemd.services.alertmanager.after = [ "ntfy-bridge.service" ];

  # Alertmanager -> ntfy formatter (see nixmonitoring/ntfy-bridge.py).
  systemd.services.ntfy-bridge = {
    description = "Format Alertmanager webhooks as ntfy notifications";
    after = [ "network-online.target" "alertmanager-secrets.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./ntfy-bridge.py}";
      # Read by systemd as root before privileges are dropped.
      EnvironmentFile = "/var/lib/secrets/alertmanager/ntfy.env";
      DynamicUser = true;
      Restart = "always";
      RestartSec = "10s";
      StateDirectory = "ntfy-bridge";
      CapabilityBoundingSet = "";
      LockPersonality = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      MemoryMax = "64M";
      TasksMax = 64;
    };
  };

  # Paging must not give up quietly either: alertmanager sat in state=failed on
  # this container after a port collision during a switch, and a dead
  # alertmanager makes every rule in the fleet silently deaf.
  systemd.services.prometheus.alertmanager = lib.mkIf config.services.prometheus.alertmanager.enable {
    unitConfig.StartLimitIntervalSec = lib.mkForce 0;
  };

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    configuration = {
      route = {
        receiver = "ntfy";
        group_by = [ "alertname" ];
        group_wait = "30s";
        group_interval = "5m";
        # Keep re-paging while something is still broken: the 2026-11-26
        # incident lasted five hours, and a single notification at 01:25 was
        # not enough to get anyone up for it.
        repeat_interval = "3h";
      };
      receivers = [
        {
          name = "ntfy";
          # The bridge is what knows about ntfy; Alertmanager only ever sees a
          # loopback URL, so this receiver holds no secret and needs no
          # substitution.
          webhook_configs = [
            {
              url = "http://127.0.0.1:9099/";
              send_resolved = true;
              max_alerts = 6;
              timeout = "20s";
            }
          ];
        }
      ];
    };
  };

  # 2. Loki Log Aggregation
  services.loki = {
    enable = true;
    configFile = pkgs.writeText "loki-local-config.yaml" ''
      auth_enabled: false
      server:
        http_listen_port: 3100
        grpc_listen_port: 9096
        # Loki's own per-query info logs were a large part of Loki's log
        # volume; keep warnings/errors only.
        log_level: warn
      common:
        ring:
          instance_addr: 127.0.0.1
          kvstore:
            store: inmemory
        replication_factor: 1
        path_prefix: /var/lib/loki
      compactor:
        working_directory: /var/lib/loki/compactor
        retention_enabled: true
        delete_request_store: filesystem
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
        # 90 days of centralized logs. Loki deletes older chunks through the
        # compactor above.
        retention_period: 2160h
    '';
  };

  # 2b. InfluxDB v2 — receives pushed metrics from Proxmox's built-in External
  # Metric Server (Datacenter → Metric Server → InfluxDB HTTP v2 API). Proxmox
  # pushes per-node and per-guest (LXC/QEMU) resource metrics natively, keeping
  # the Proxmox host untouched (no third-party exporters, API tokens, or venvs).
  # Configure the Proxmox side with scratch/setup-proxmox-metric-server.sh.
  services.influxdb2 = {
    enable = true;
    settings = {
      "http-bind-address" = ":8086";
    };
  };

  # Initialize InfluxDB on first boot: create org "minnecker", bucket
  # "proxmox", and a token with full read/write on that bucket. The token
  # is stored at /var/lib/secrets/influxdb/token and consumed by both the
  # Grafana datasource (read) and the Proxmox metric-server setup script
  # (write). Idempotent: if InfluxDB is already set up, the oneshot exits 0.
  systemd.services.influxdb-init = {
    description = "Initialize InfluxDB v2 org, bucket, and token";
    wantedBy = [ "multi-user.target" ];
    after = [ "influxdb2.service" ];
    bindsTo = [ "influxdb2.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.influxdb2 pkgs.curl pkgs.coreutils pkgs.jq pkgs.openssl ];
    script = ''
      set -euo pipefail
      d=/var/lib/secrets/influxdb
      mkdir -p "$d"

      # The influx CLI in this version has no --org flag for `bucket update`;
      # set the 90-day retention through the HTTP API instead.
      set_retention() {
        tok="$1"
        id=$(curl -sf -H "Authorization: Token $tok" \
          "http://127.0.0.1:8086/api/v2/buckets?name=proxmox" | ${pkgs.jq}/bin/jq -r '.buckets[0].id')
        if [ -n "$id" ] && [ "$id" != "null" ]; then
          curl -sf -X PATCH -H "Authorization: Token $tok" \
            -H "Content-Type: application/json" \
            -d '{"retentionRules":[{"type":"expire","everySeconds":7776000}]}' \
            "http://127.0.0.1:8086/api/v2/buckets/$id" >/dev/null || true
        fi
      }

      # Wait for InfluxDB HTTP API to accept connections.
      for i in {1..30}; do
        if curl -sf http://127.0.0.1:8086/health >/dev/null 2>&1; then break; fi
        sleep 1
      done
      curl -sf http://127.0.0.1:8086/health >/dev/null 2>&1 || {
        echo "InfluxDB not ready after 30s" >&2; exit 1; }

      # If the token file already exists, InfluxDB was initialized before.
      if [ -s "$d/token" ]; then
        echo "InfluxDB already initialized (token file exists)."
        # Verify the token still works; if not, fall through to re-init.
        if curl -sf -H "Authorization: Token $(cat "$d/token")" \
             "http://127.0.0.1:8086/api/v2/buckets?name=proxmox" >/dev/null 2>&1; then
          ADMIN_TOKEN="$(cat "$d/admin-token" 2>/dev/null || cat "$d/token")"
          set_retention "$ADMIN_TOKEN"
          exit 0
        fi
        echo "Token invalid, re-initializing..."
      fi

      # Generate a deterministic token so the Proxmox setup script (run
      # separately on the Proxmox host) can read it from the same file.
      TOKEN="$(head -c 48 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_')"

      # influx setup is idempotent-safe with --force (skips if already set up,
      # but the --token flag sets the initial admin token on first run).
      influx setup \
        --host http://127.0.0.1:8086 \
        --org minnecker \
        --bucket proxmox \
        --username admin \
        --password "$(openssl rand -base64 24)" \
        --token "$TOKEN" \
        --force 2>/dev/null || true

      # If setup above didn't work (already set up), create a new token via
      # the admin token if one was stored from a previous run.
      if [ -s "$d/admin-token" ]; then
        ADMIN_TOKEN="$(cat "$d/admin-token")"
        # Create an all-access token on the proxmox bucket.
        NEW_TOKEN=$(curl -sf -X POST \
          "http://127.0.0.1:8086/api/v2/authorizations" \
          -H "Authorization: Token $ADMIN_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"orgID\":\"$(curl -sf -H "Authorization: Token $ADMIN_TOKEN" http://127.0.0.1:8086/api/v2/orgs?org=minnecker | ${pkgs.jq}/bin/jq -r .orgs[0].id)\",\"description\":\"proxmox-rw\",\"permissions\":[{\"action\":\"read\",\"resource\":{\"type\":\"buckets\",\"id\":\"$(curl -sf -H "Authorization: Token $ADMIN_TOKEN" http://127.0.0.1:8086/api/v2/buckets?name=proxmox | ${pkgs.jq}/bin/jq -r .buckets[0].id)\"}},{\"action\":\"write\",\"resource\":{\"type\":\"buckets\",\"id\":\"$(curl -sf -H "Authorization: Token $ADMIN_TOKEN" http://127.0.0.1:8086/api/v2/buckets?name=proxmox | ${pkgs.jq}/bin/jq -r .buckets[0].id)\"}}]}" \
          | ${pkgs.jq}/bin/jq -r .token) || true
        if [ -n "$NEW_TOKEN" ]; then
          TOKEN="$NEW_TOKEN"
        fi
      fi

      printf '%s' "$TOKEN" > "$d/token"
      chmod 640 "$d/token"
      chown root:grafana "$d/token"
      # Also store the initial admin token for future token management.
      if [ ! -s "$d/admin-token" ]; then
        printf '%s' "$TOKEN" > "$d/admin-token"
        chmod 644 "$d/admin-token"
      fi
      set_retention "$(cat "$d/admin-token" 2>/dev/null || echo "$TOKEN")"
      echo "InfluxDB initialized: org=minnecker bucket=proxmox token=$d/token"
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
        # Disallow account creation via the built-in form and hide the
        # username/password box on the login page. SSO via Kanidm is the
        # only way in. (admin_password above still exists as an escape
        # hatch for emergency/break-glass access, but the form is hidden.)
        disable_gravatar = true;
      };
      "auth" = {
        disable_login_form = true;
      };
      "auth.basic" = {
        enabled = false;
      };
      "auth.generic_oauth" = {
        enabled = true;
        name = "Kanidm SSO";
        allow_sign_up = true;
        client_id = "grafana";
        client_secret = "$__file{/var/lib/secrets/oauth2/grafana/secret}";
        scopes = "openid email profile groups";
        # Kanidm has two authorise endpoints: the raw /oauth2/authorise (which
        # requires an existing session and 401s with NotAuthenticated otherwise)
        # and /ui/oauth2 (which drives the login/consent UI for unauthenticated
        # users). Forgejo reaches the latter via OIDC auto-discovery, but
        # Grafana's generic_oauth plugin has no discovery mode, so auth_url is
        # hardcoded here. It MUST point at the UI endpoint — using the raw
        # endpoint surfaces as a 401 NotAuthenticated the moment oauth_auto_login
        # sends the user there without a session cookie.
        auth_url = "https://idm.minnecker.com/ui/oauth2";
        token_url = "https://idm.minnecker.com/oauth2/token";
        api_url = "https://idm.minnecker.com/oauth2/openid/grafana/userinfo";
        role_attribute_path = "contains(groups, 'idm_admins') && 'GrafanaAdmin' || contains(groups, 'admin') && 'Admin' || contains(groups, 'grafana_admins') && 'Admin' || 'Viewer'";
        # allow_assign_grafana_admin: without this, even a 'GrafanaAdmin' result
        # from role_attribute_path only grants org admin, not server admin (the
        # ability to manage data sources, server settings, and users). Members
        # of idm_admins get full server admin; grafana_admins get org admin.
        allow_assign_grafana_admin = true;
        # Kanidm enforces PKCE on all OAuth2 clients; Grafana's generic_oauth
        # plugin supports it, so send a code_challenge with the authorise
        # request. Without this Kanidm rejects with "No PKCE code challenge
        # was provided with client in enforced PKCE mode".
        use_pkce = true;
        # Send unauthenticated users straight to Kanidm instead of showing
        # a login screen with a (now hidden) form.
        oauth_auto_login = true;
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
        {
          # InfluxDB v2 — stores Proxmox-pushed hypervisor metrics. Grafana
          # queries it with Flux. The token is the same file InfluxDB-init
          # writes, granting read access to the proxmox bucket.
          name = "InfluxDB";
          type = "influxdb";
          access = "proxy";
          url = "http://127.0.0.1:8086";
          uid = "influxdb";
          jsonData = {
            version = "Flux";
            organization = "minnecker";
            defaultBucket = "proxmox";
            tlsSkipVerify = true;
          };
          secureJsonData = {
            token = "$__file{/var/lib/secrets/influxdb/token}";
          };
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
    "L+ /var/lib/grafana/dashboards/mail-ops.json - - - - ${./dashboards/mail-ops.json}"
    "L+ /var/lib/grafana/dashboards/ai-usage.json - - - - ${./dashboards/ai-usage.json}"
    "L+ /var/lib/grafana/dashboards/security.json - - - - ${./dashboards/security.json}"
  ];
}
