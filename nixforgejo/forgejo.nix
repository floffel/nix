# NixOS Service Configuration for Forgejo (Git with Actions enabled)
{ config, pkgs, lib, ... }:

{
  services.forgejo = {
    enable = true;
    
    # Configure PostgreSQL database on the remote host nixpostgres
    database = {
      type = "postgres";
      host = "nixpostgres";
      name = "forgejo";
      user = "forgejo";
      passwordFile = "/var/lib/secrets/postgres/forgejo/db-password";
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

      service = {
        DISABLE_REGISTRATION = true; 
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
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

  # The forgejo database password is read from the shared Postgres secrets
  # mount at /var/lib/secrets/postgres/forgejo/db-password (bind-mounted
  # read-only, provisioned on nixpostgres). The OAuth2 client secret lives on
  # the shared OAuth2 secrets mount at /var/lib/secrets/oauth2/forgejo/secret,
  # which is bind-mounted read-only here and read-write on nixidm — the same
  # file Kanidm provisions, so the two can never drift (no manual sync
  # needed). No local secrets directory is required on this container; the
  # Forgejo Actions runner token lives in the separate nixforgejo-runner
  # container.

  # Post-start script to register and reconcile the OAuth2/OIDC (kanidm)
  # authentication source, keeping its client secret in sync on every boot.
  systemd.services.forgejo = {
    path = [ pkgs.gawk ];
    postStart = ''
      export FORGEJO_WORK_DIR=${config.services.forgejo.stateDir}
      
      # Wait for Forgejo database and service port to be fully available
      for i in {1..15}; do
        if ${config.services.forgejo.package}/bin/forgejo admin auth list --config /var/lib/forgejo/custom/conf/app.ini >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      # The OIDC auth source is reconciled on every boot: if it does not yet
      # exist it is created, and in both cases its client secret is rewritten
      # to the current contents of the shared secret file. The file is the same
      # one Kanidm's provisioning hook reads (bind-mounted from the NAS), so
      # Forgejo's stored secret always matches what Kanidm expects — the
      # "OAuth2 RetrieveError: ... 401 Unauthorized" drift can no longer occur.
      AUTH_ID="$(${config.services.forgejo.package}/bin/forgejo admin auth list --config /var/lib/forgejo/custom/conf/app.ini | awk -F'\t' 'NR>1 && $2 ~ /kanidm/ {gsub(/^ +| +$/,"",$1); print $1; exit}')"
      if [ -n "$AUTH_ID" ]; then
        ${config.services.forgejo.package}/bin/forgejo admin auth update-oauth \
          --config /var/lib/forgejo/custom/conf/app.ini \
          --id "$AUTH_ID" \
          --name "kanidm" \
          --secret "$(cat /var/lib/secrets/oauth2/forgejo/secret)" \
          --auto-discover-url "https://idm.minnecker.com/oauth2/openid/forgejo/.well-known/openid-configuration" \
          --scopes "openid email profile"
      else
        # First-time creation: register the OIDC connection.
        ${config.services.forgejo.package}/bin/forgejo admin auth add-oauth \
          --config /var/lib/forgejo/custom/conf/app.ini \
          --name "kanidm" \
          --provider "openidConnect" \
          --key "forgejo" \
          --secret "$(cat /var/lib/secrets/oauth2/forgejo/secret)" \
          --auto-discover-url "https://idm.minnecker.com/oauth2/openid/forgejo/.well-known/openid-configuration" \
          --scopes "openid email profile"
      fi
    '';
  };
}
