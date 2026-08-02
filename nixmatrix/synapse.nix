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

      # Database connection and OIDC config live in a runtime-generated
      # secrets.yaml (see matrix-synapse-secrets-config oneshot below).
      # Both are excluded from settings here because Synapse shallow-merges
      # extraConfigFiles — top-level keys from the extra file replace the
      # main config entirely, so the full block must be in one place.

      # Auto-provision new users on first OIDC login. password_config.enabled
      # is false (below) so manual signup via username/password is impossible
      # — only SSO creates accounts.
      enable_registration = true;

      # SSO-only login: hide the username/password form so Kanidm OIDC is the
      # only way in (matches the new identity-based setup).
      password_config = {
        enabled = false;
      };
    };

    # Load the runtime-generated config with database and OIDC secrets.
    # This file lives on the writable local filesystem, not the read-only
    # secrets mount, so it can be regenerated on every start.
    extraConfigFiles = [
      "/var/lib/matrix-synapse/secrets.yaml"
    ];
  };

  # Generate a fresh secrets.yaml on every service start with the real
  # credentials from the shared secrets mounts. Runs as root (no systemd
  # seccomp sandbox) before matrix-synapse, so sed-in-place and mount
  # permissions are irrelevant — cat into a writable local path.
  systemd.services.matrix-synapse-secrets-config = {
    description = "Generate Matrix Synapse runtime config (database + OIDC)";
    wantedBy = [ "matrix-synapse.service" ];
    before = [ "matrix-synapse.service" ];
    partOf = [ "matrix-synapse.service" ];
    bindsTo = [ "matrix-synapse.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail

      OUT=/var/lib/matrix-synapse/secrets.yaml

      DBPW=$(cat /var/lib/secrets/postgres/matrix/db-password 2>/dev/null || echo "PLACEHOLDER")
      CLIENTSECRET=$(cat /var/lib/secrets/oauth2/matrix/secret 2>/dev/null || echo "PLACEHOLDER")

      install -d -m 755 -o matrix-synapse -g matrix-synapse "$(dirname "$OUT")"

      cat > "$OUT" <<EOF
database:
  name: "psycopg2"
  args:
    user: "matrix"
    database: "matrix"
    host: "nixpostgres"
    port: 5432
    password: "$DBPW"
  allow_unsafe_locale: true
oidc_providers:
  - idp_id: "kanidm"
    idp_name: "Kanidm SSO"
    issuer: "https://idm.minnecker.com/oauth2/openid/matrix"
    client_id: "matrix"
    client_secret: "$CLIENTSECRET"
    scopes: ["openid", "profile", "email"]
    user_mapping_provider:
      config:
        subject_claim: "sub"
        localpart_claim: "preferred_username"
        display_name_claim: "name"
        email_claim: "email"
EOF
      chown matrix-synapse:matrix-synapse "$OUT"
      chmod 600 "$OUT"
    '';
  };
}
