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

  # Ensure the secrets directory and its files are owned by the forgejo user
  # so the postStart hook (which runs as forgejo) can read them. Secrets are
  # often pushed via `ssh ... 'cat > file'` (which writes as root); this rule
  # reconciles ownership on every boot without touching the file contents.
  systemd.tmpfiles.rules = [
    "d /var/lib/secrets/forgejo 0700 forgejo forgejo -"
    "Z /var/lib/secrets/forgejo 0700 forgejo forgejo -"
  ];

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
      # to the current contents of the secret file. The Kanidm provisioning
      # hook re-applies the *same* secret to the OAuth2 client on every Kanidm
      # restart, so keeping Forgejo's stored secret in sync avoids a stale
      # "OAuth2 RetrieveError: ... 401 Unauthorized" at token exchange when the
      # secret file has been (re)generated after the source was first created.
      AUTH_ID="$(${config.services.forgejo.package}/bin/forgejo admin auth list --config /var/lib/forgejo/custom/conf/app.ini | awk -F'\t' 'NR>1 && $2 ~ /kanidm/ {gsub(/^ +| +$/,"",$1); print $1; exit}')"
      if [ -n "$AUTH_ID" ]; then
        ${config.services.forgejo.package}/bin/forgejo admin auth update-oauth \
          --config /var/lib/forgejo/custom/conf/app.ini \
          --id "$AUTH_ID" \
          --name "kanidm" \
          --secret "$(cat /var/lib/secrets/forgejo/oauth-secret)" \
          --auto-discover-url "https://idm.minnecker.com/oauth2/openid/forgejo/.well-known/openid-configuration" \
          --scopes "openid email profile"
      else
        # First-time creation: register the OIDC connection.
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
