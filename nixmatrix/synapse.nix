# NixOS Service Configuration for Matrix Synapse
{ config, pkgs, lib, ... }:

{
  services.matrix-synapse = {
    enable = true;
    
    # Ensure OIDC python package is loaded for OIDC SSO support
    extras = [ "oidc" ];

    settings = {
      server_name = "minnecker.com";
      public_baseurl = "https://matrix.minnecker.com/";
      
      # Bind listeners to port 8008 for unencrypted HTTP reverse proxy traffic from Nginx
      listeners = [
        {
          port = 8008;
          bind_addresses = [ "::" ];
          type = "http";
          tls = false;
          # Trust X-Forwarded-For from the nixnginx reverse proxy so Synapse
          # logs and tracks the real client IP instead of the proxy address.
          x_forwarded = true;
          resources = [
            {
              names = [ "client" ];
              compress = true;
            }
            {
              names = [ "federation" ];
              compress = false;
            }
          ];
        }
      ];

      # Connect to PostgreSQL on nixpostgres container
      database = {
        name = "psycopg2";
        args = {
          user = "matrix";
          database = "matrix";
          host = "nixpostgres";
          port = 5432;
          # Password loaded from extraConfigFiles to avoid store leak
        };
      };

      # Disable public registration (new accounts created only via SSO)
      enable_registration = false;

      # Configure OAuth/OIDC against Kanidm SSO
      # Note: oidc_providers is configured in /var/lib/secrets/matrix/secrets.yaml
      # to prevent exposing the client_secret in the Nix store. A preStart hook
      # rewrites the client_secret line in that file from the shared OAuth2
      # secret mount on every start so it can never drift from Kanidm's value.
    };

    # Load sensitive data (database password, OIDC client secret) at startup from runtime file
    extraConfigFiles = [
      "/var/lib/secrets/matrix/secrets.yaml"
    ];
  };

  # Provision the secrets.yaml file idempotently on first boot, mirroring the
  # grafana-secrets / vaultwarden-secrets pattern. The file only contains
  # placeholders for the OIDC client config (no real secret material); the
  # matrix-synapse.preStart hook below rewrites the two placeholder lines from
  # the shared NAS mounts on every start so they can never drift. Existing
  # files are never overwritten, so manual edits survive rebuilds.
  systemd.services.matrix-synapse-secrets = {
    description = "Provision Matrix Synapse secrets.yaml";
    wantedBy = [ "matrix-synapse.service" ];
    before = [ "matrix-synapse.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils ];
    script = ''
      d=/var/lib/secrets/matrix
      f="$d/secrets.yaml"
      mkdir -p "$d"
      if [ ! -s "$f" ]; then
        echo "Writing $f with placeholder secrets"
        cat > "$f" <<'EOF'
      database:
        args:
          password: "PLACEHOLDER_REWRITTEN_FROM_SHARED_MOUNT"
      oidc_providers:
        - idp_id: "kanidm"
          idp_name: "Kanidm SSO"
          issuer: "https://idm.minnecker.com/oauth2/openid/matrix"
          client_id: "matrix"
          client_secret: "PLACEHOLDER_REWRITTEN_FROM_SHARED_MOUNT"
          scopes: ["openid", "profile", "email"]
          user_mapping_provider:
            config:
              subject_claim: "sub"
              localpart_claim: "preferred_username"
              display_name_claim: "name"
              email_claim: "email"
      EOF
      fi
      chown matrix-synapse:matrix-synapse "$f"
      chmod 600 "$f"
    '';
  };

  # Keep secrets.yaml in sync with the shared secrets mounts on every start:
  #   * the OIDC client_secret is rewritten from the shared OAuth2 secret file
  #     that Kanidm provisions (/var/lib/secrets/oauth2/matrix/secret, the same
  #     file nixidm reads), avoiding a stale secret -> 401 at token exchange.
  #   * the database password is rewritten from the shared Postgres secrets
  #     mount (/var/lib/secrets/postgres/matrix/db-password, provisioned on
  #     nixpostgres), so Postgres remains the sole writer of DB passwords and
  #     the value in secrets.yaml can never drift from the role's password.
  systemd.services.matrix-synapse.preStart = ''
    YAML_FILE="/var/lib/secrets/matrix/secrets.yaml"

    SECRET_FILE="/var/lib/secrets/oauth2/matrix/secret"
    if [ -r "$SECRET_FILE" ] && [ -f "$YAML_FILE" ]; then
      SECRET=$(cat "$SECRET_FILE")
      grep -q '^[[:space:]]*client_secret:' "$YAML_FILE" || { echo "Error: client_secret: line not found in $YAML_FILE" >&2; exit 1; }
      ${pkgs.gnused}/bin/sed -i -E \
        "s#^([[:space:]]*)client_secret:.*#\1client_secret: \"$SECRET\"#" \
        "$YAML_FILE"
    fi

    DBPW_FILE="/var/lib/secrets/postgres/matrix/db-password"
    if [ -r "$DBPW_FILE" ] && [ -f "$YAML_FILE" ]; then
      DBPW=$(cat "$DBPW_FILE")
      grep -q '^[[:space:]]*password:' "$YAML_FILE" || { echo "Error: password: line not found in $YAML_FILE" >&2; exit 1; }
      ${pkgs.gnused}/bin/sed -i -E \
        "s#^([[:space:]]*)password:.*#\1password: \"$DBPW\"#" \
        "$YAML_FILE"
    fi
  '';
}
