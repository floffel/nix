# NixOS Service Configuration for Vaultwarden
{ config, pkgs, lib, ... }:

{
  services.vaultwarden = {
    enable = true;

    # Build the vaultwarden binary with the postgres backend enabled. The
    # default dbBackend is "sqlite" — without this, Vaultwarden refuses a
    # PostgreSQL DATABASE_URL ("the 'postgresql' feature is not enabled").
    dbBackend = "postgresql";

    # Configure non-sensitive settings declaratively
    config = {
      ROCKET_ADDRESS = "::";
      ROCKET_PORT = 8080;

      # Signups disabled by default. Admin can override this or use invitation links.
      SIGNUPS_ALLOWED = false;

      # Enable websocket support for real-time client synchronization
      WEBSOCKET_ENABLED = true;

      # DATABASE_URL is intentionally NOT set here (it would leak the DB
      # topology into the Nix store and be dead config anyway). It is assembled
      # at runtime by the vaultwarden-secrets unit from the shared Postgres
      # secrets mount and written to /run/vaultwarden/env (see below).

      # SSO (OpenID Connect) via Kanidm. SSO_CLIENT_SECRET is also injected at
      # runtime from the shared OAuth2 secrets mount (see vaultwarden-secrets
      # below) so the secret never enters the Nix store. Kanidm's OIDC
      # discovery is per-client: the issuer URL is the client-specific base
      # (.../oauth2/openid/<client_id>), to which Vaultwarden appends
      # /.well-known/openid-configuration (via openidconnect's discover_async).
      DOMAIN = "https://vault.minnecker.com";
      SSO_ENABLED = true;
      SSO_ONLY = true;
      SSO_AUTHORITY = "https://idm.minnecker.com/oauth2/openid/vaultwarden";
      SSO_CLIENT_ID = "vaultwarden";
      SSO_SCOPES = "email profile";
      SSO_PKCE = true;
    };

    # The runtime environment file is assembled by the vaultwarden-secrets
    # unit (see below) from the per-container template (ADMIN_TOKEN) plus the
    # database password read from the shared Postgres secrets mount
    # (/var/lib/secrets/postgres/vaultwarden/db-password, provisioned on
    # nixpostgres and bind-mounted read-only here). This keeps Postgres the
    # sole writer of DB passwords while leaving the admin token in the
    # container-local template.
    environmentFile = "/run/vaultwarden/env";
  };

  # Per-container secret template holding only non-DB secrets (admin token).
  # The DB password is injected from the shared mount at runtime, so this file
  # never contains a DATABASE_URL with an embedded password.

  # Auto-provision the admin token on first boot. The token is a per-container
  # secret (not shared with the IdP like the OAuth2 client secret), so it is
  # generated locally with openssl if the template is missing rather than
  # shipped from a shared mount. Runs before vaultwarden-secrets so the
  # template exists before assembly; idempotent (no-op if already populated).
  systemd.services.vaultwarden-admin-token = {
    description = "Provision Vaultwarden ADMIN_TOKEN if missing";
    wantedBy = [ "vaultwarden.service" ];
    before = [ "vaultwarden-secrets.service" "vaultwarden.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.openssl pkgs.coreutils ];
    script = ''
      set -euo pipefail
      install -d -m 700 -o vaultwarden -g vaultwarden /var/lib/secrets/vaultwarden
      tpl=/var/lib/secrets/vaultwarden/env-template
      if [ ! -s "$tpl" ]; then
        echo "Generating new ADMIN_TOKEN..."
        token=$(openssl rand -base64 48)
        ( umask 077
          printf 'ADMIN_TOKEN=%s\n' "$token" > "$tpl"
        )
        chmod 600 "$tpl"
        chown vaultwarden:vaultwarden "$tpl"
        echo "ADMIN_TOKEN written to $tpl (value not logged)."
      else
        echo "ADMIN_TOKEN template already present — keeping it."
      fi
    '';
  };

  # Assemble the runtime env file on every start of vaultwarden from the
  # template (ADMIN_TOKEN), the DB password pulled from the shared Postgres
  # secrets mount, and the OIDC client secret pulled from the shared OAuth2
  # secrets mount (/var/lib/secrets/oauth2/vaultwarden/secret, provisioned on
  # nixidm and bind-mounted read-only here). partOf + bindsTo couple this
  # oneshot to vaultwarden.service so it re-runs on every (re)start of the
  # service (not just at boot), keeping the tmpfs env file fresh;
  # RemainAfterExit is omitted so each restart re-assembles it.
  systemd.services.vaultwarden-secrets = {
    description = "Assemble Vaultwarden runtime env from template + shared DB password";
    wantedBy = [ "vaultwarden.service" ];
    before = [ "vaultwarden.service" ];
    partOf = [ "vaultwarden.service" ];
    bindsTo = [ "vaultwarden.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      template=/var/lib/secrets/vaultwarden/env-template
      dbpw_file=/var/lib/secrets/postgres/vaultwarden/db-password
      sso_secret_file=/var/lib/secrets/oauth2/vaultwarden/secret
      out=/run/vaultwarden/env
      install -d -m 700 -o vaultwarden -g vaultwarden /run/vaultwarden
      if [ ! -s "$template" ]; then
        echo "Error: $template missing or empty — create it with ADMIN_TOKEN" >&2
        exit 1
      fi
      if [ ! -s "$dbpw_file" ]; then
        echo "Error: $dbpw_file missing or empty (is the shared Postgres mount attached?)" >&2
        exit 1
      fi
      if [ ! -s "$sso_secret_file" ]; then
        echo "Error: $sso_secret_file missing or empty (is the shared OAuth2 mount attached?)" >&2
        exit 1
      fi
      dbpw="$(cat "$dbpw_file")"
      sso_secret="$(cat "$sso_secret_file")"
      # Write with a restrictive umask so the file is never world/group-readable,
      # even momentarily, before the chmod below.
      ( umask 077
        cp "$template" "$out"
        # DATABASE_URL uses the password from the shared mount; postgres is the
        # sole writer so this never drifts from the role's actual password.
        printf 'DATABASE_URL=postgresql://vaultwarden:%s@nixpostgres/vaultwarden\n' "$dbpw" >> "$out"
        # SSO_CLIENT_SECRET from the shared OAuth2 secrets mount (provisioned on
        # nixidm). Kanidm's provisioning hook re-applies it on every restart,
        # so this is authoritative and never drifts from the IdP's value.
        printf 'SSO_CLIENT_SECRET=%s\n' "$sso_secret" >> "$out"
      )
      chmod 600 "$out"
      chown vaultwarden:vaultwarden "$out"
    '';
  };
}
