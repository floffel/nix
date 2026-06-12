# NixOS Service Configuration for Forgejo (Git with Actions enabled)
{ config, pkgs, lib, ... }:

{
  services.forgejo = {
    enable = true;
    
    # Configure PostgreSQL database on the remote host postgresqlng
    database = {
      type = "postgres";
      host = "postgresqlng";
      name = "forgejo";
      user = "forgejo";
      passwordFile = "/var/lib/secrets/forgejo/db-password";
    };

    # Forgejo configuration file settings
    settings = {
      DEFAULT = {
        APP_NAME = "Minnecker Forgejo";
      };
      server = {
        DOMAIN = "git.minnecker.com";
        ROOT_URL = "https://git.minnecker.com/";
        HTTP_ADDR = "0.0.0.0";
        HTTP_PORT = 3000;
      };

      # Enable Forgejo Actions (CI/CD)
      actions = {
        ENABLED = true;
      };

      # Enable Prometheus metrics endpoint
      metrics = {
        ENABLED = true;
      };
    };
  };

  # Post-start script to automatically register OAuth2/OIDC authentication source if not already present
  systemd.services.forgejo = {
    postStart = ''
      export FORGEJO_WORK_DIR=${config.services.forgejo.stateDir}
      
      # Wait for Forgejo database and service port to be fully available
      for i in {1..15}; do
        if ${config.services.forgejo.package}/bin/forgejo admin auth list --config /var/lib/forgejo/custom/conf/app.ini >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      # Check if "kanidm" authentication source exists
      if ! ${config.services.forgejo.package}/bin/forgejo admin auth list --config /var/lib/forgejo/custom/conf/app.ini | grep -q "kanidm"; then
        # Add OAuth2/OIDC connection
        ${config.services.forgejo.package}/bin/forgejo admin auth add-oauth \
          --config /var/lib/forgejo/custom/conf/app.ini \
          --name "kanidm" \
          --provider "openidConnect" \
          --key "forgejo" \
          --secret "$(cat /var/lib/secrets/forgejo/oauth-secret)" \
          --auto-discover-url "https://idm.minnecker.com/oauth2/openid/forgejo/.well-known/openid-configuration" \
          --scopes "openid email profile"
      fi
    '';
  };
}
