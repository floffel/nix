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
          bind_addresses = [ "0.0.0.0" ];
          type = "http";
          tls = false;
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

  # Keep the OIDC client_secret in secrets.yaml in sync with the shared secret
  # file that Kanidm provisions (/var/lib/secrets/oauth2/matrix/secret, the same
  # file nixidm reads). This avoids a stale secret -> 401 at token exchange.
  systemd.services.matrix-synapse.preStart = ''
    SECRET_FILE="/var/lib/secrets/oauth2/matrix/secret"
    YAML_FILE="/var/lib/secrets/matrix/secrets.yaml"
    if [ -r "$SECRET_FILE" ] && [ -f "$YAML_FILE" ]; then
      SECRET=$(cat "$SECRET_FILE")
      ${pkgs.gnused}/bin/sed -i \
        "s#^      client_secret:.*#      client_secret: \"$SECRET\"#" \
        "$YAML_FILE"
    fi
  '';
}
