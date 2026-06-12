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

      # Connect to PostgreSQL on postgresqlng container
      database = {
        name = "psycopg2";
        args = {
          user = "matrix";
          database = "matrix";
          host = "postgresqlng";
          port = 5432;
          # Password loaded from extraConfigFiles to avoid store leak
        };
      };

      # Disable public registration (new accounts created only via SSO)
      enable_registration = false;

      # Configure OAuth/OIDC against Kanidm SSO
      # Note: oidc_providers is configured in /var/lib/secrets/matrix/secrets.yaml
      # to prevent exposing the client_secret in the Nix store.
    };

    # Load sensitive data (database password, OIDC client secret) at startup from runtime file
    extraConfigFiles = [
      "/var/lib/secrets/matrix/secrets.yaml"
    ];
  };
}
