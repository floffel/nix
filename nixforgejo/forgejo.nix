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
        HTTP_ADDR = "::";
        HTTP_PORT = 3000;

        # Forgejo's built-in SSH server for git clone/push via ssh://
        SSH_PORT = 2222;

        # Forgejo sits behind the nixnginx reverse proxy. Trust the forwarded
        # client-IP headers it sends so logs, rate limiting and audit entries
        # show the real remote client instead of the proxy's address.
        # REVERSE_PROXY_TRUSTED_PROXIES accepts CIDR ranges; nginx reaches us
        # from both the service LAN (172.16.16.3) and the LXC mgmt LAN
        # (10.20.20.14), plus their IPv6 link addresses.
        REVERSE_PROXY_LIMITER = true;
        REVERSE_PROXY_TRUSTED_PROXIES = "172.16.16.3/32, 10.20.20.14/32, fd0c:dead:beef::16:3/128, fd01::14/128, 127.0.0.1/32";
      };

      service = {
        # DISABLE_REGISTRATION must be false for ALLOW_ONLY_EXTERNAL_REGISTRATION
        # and ENABLE_AUTO_REGISTRATION (oauth2_client) to work — the Gitea/Forgejo
        # docs state ALLOW_ONLY_EXTERNAL_REGISTRATION only takes effect when
        # DISABLE_REGISTRATION is false. With it true, the external/OIDC
        # registration path is blocked and SSO users land on the link_account
        # page instead of being auto-provisioned.
        DISABLE_REGISTRATION = false;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
        # Forgejo (unlike Gitea) uses ENABLE_INTERNAL_SIGNIN to control the
        # password login form, not ENABLE_PASSWORD_SIGNIN_FORM. Setting it to
        # false hides the username/password form so only the Kanidm SSO button
        # remains on the login page. The local admin account can still manage
        # the instance via the CLI (`forgejo admin user ...`).
        # Note: the key is ENABLE_INTERNAL_SIGNIN (no underscore between SIGN
        # and IN) — Forgejo's setting loader reads exactly that string.
        ENABLE_INTERNAL_SIGNIN = false;
      };

      # Auto-provision Forgejo accounts from Kanidm OIDC claims. Without
      # ENABLE_AUTO_REGISTRATION a first-time SSO user lands on a blank
      # "complete account" page because no local user exists yet. With it on,
      # Forgejo creates the account automatically from the returned claims.
      # USERNAME = userid uses the OIDC `sub` claim (always present, unique,
      # stable) as the local username — Kanidm's profile scope returns `name`
      # but not `nickname`/`preferred_username`, so the Gitea/Forgejo default
      # (`nickname`) yields an empty username.
      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true;
        USERNAME = "userid";
        UPDATE_AVATAR = false;
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
    path = [ pkgs.gawk pkgs.util-linux ];
    postStart = ''
      (
        flock -n 9 || { echo "Forgejo OIDC reconcile already running (lock held)"; exit 0; }
        export FORGEJO_WORK_DIR=${config.services.forgejo.stateDir}

        for i in {1..15}; do
          if ${config.services.forgejo.package}/bin/forgejo admin auth list --config /var/lib/forgejo/custom/conf/app.ini >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

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
          ${config.services.forgejo.package}/bin/forgejo admin auth add-oauth \
            --config /var/lib/forgejo/custom/conf/app.ini \
            --name "kanidm" \
            --provider "openidConnect" \
            --key "forgejo" \
            --secret "$(cat /var/lib/secrets/oauth2/forgejo/secret)" \
            --auto-discover-url "https://idm.minnecker.com/oauth2/openid/forgejo/.well-known/openid-configuration" \
            --scopes "openid email profile"
        fi
      ) 9>/var/lib/forgejo/oidc-reconcile.lock
    '';
  };
}
