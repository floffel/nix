# NixOS Service Configuration for Wiki.js
{ config, pkgs, lib, ... }:

{
  services.wiki-js = {
    enable = true;

    # Configure settings matching upstream JSON/YAML keys
    settings = {
      port = 3000;
      bindIP = "::";
      # Trust X-Forwarded-For from the nixnginx reverse proxy so Wiki.js
      # records the real client IP instead of the proxy address.
      trustProxy = true;
      db = {
        type = "postgres";
        host = "nixpostgres";
        port = 5432;
        user = "wikijs";
        # WIKI_DB_PASS is injected at runtime from the shared Postgres
        # secrets mount via the environmentFile assembled by
        # wikijs-secrets (see below).
        pass = "$(WIKI_DB_PASS)";
        db = "wikijs";
        ssl = false;
      };
    };

    # The runtime environment file is assembled by the wikijs-secrets unit
    # (see below) from the per-container template plus the database password
    # read from the shared Postgres secrets mount
    # (/var/lib/secrets/postgres/wikijs/db-password, provisioned on
    # nixpostgres and bind-mounted read-only here). This keeps Postgres the
    # sole writer of DB passwords.
    environmentFile = "/run/wikijs/env";
  };

  # Assemble the runtime env file on every start of wiki-js from the DB
  # password pulled from the shared Postgres secrets mount. partOf + bindsTo
  # couple this oneshot to wiki-js.service so it re-runs on every (re)start
  # (not just at boot), keeping the tmpfs env file fresh; RemainAfterExit is
  # omitted so each restart re-assembles it.
  #
  # The wiki-js module uses DynamicUser, so there is no static system user to
  # chown the file to. systemd reads EnvironmentFile as root before dropping
  # privileges, so a root-owned 0600 file is readable by the dynamic service
  # user via the manager — no chown needed.
  systemd.services.wikijs-secrets = {
    description = "Assemble Wiki.js runtime env from shared DB password";
    wantedBy = [ "wiki-js.service" ];
    before = [ "wiki-js.service" ];
    partOf = [ "wiki-js.service" ];
    bindsTo = [ "wiki-js.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      dbpw_file=/var/lib/secrets/postgres/wikijs/db-password
      out=/run/wikijs/env
      install -d -m 700 /run/wikijs
      if [ ! -s "$dbpw_file" ]; then
        echo "Error: $dbpw_file missing or empty (is the shared Postgres mount attached?)" >&2
        exit 1
      fi
      dbpw="$(cat "$dbpw_file")"
      # Write with a restrictive umask so the file is never world/group-readable,
      # even momentarily, before the chmod below.
      ( umask 077; printf 'WIKI_DB_PASS=%s\n' "$dbpw" > "$out" )
      chmod 600 "$out"
    '';
  };

  # Fully declarative Wiki.js bootstrap, eliminating the interactive setup
  # wizard and the manual OIDC strategy configuration.
  #
  # Wiki.js has no env-var or config-file way to declare authentication
  # strategies — they live only in the `authentication` table of its Postgres
  # DB, and the only supported writer is the `updateStrategies` GraphQL
  # mutation or the admin UI. The setup wizard is likewise unavoidable
  # upstream: `server/core/config.js` flips `config.setup = true` whenever the
  # `settings` table is empty, and the wizard (`server/setup.js`) is a tiny
  # Express app exposing `POST /finalize` that takes a JSON body
  # (adminEmail/adminPassword/siteUrl/telemetry) and performs the one-time
  # bootstrap (RSA certs, sessionSecret, default groups/users/locale/nav,
  # local auth strategy). It has no CSRF/captcha, so it can be driven with
  # curl — exactly like nextcloud's `occ user_oidc:provider` registration.
  #
  # Flow (runs after wiki-js.service on every (re)start, idempotent):
  #   1. Ensure a local admin-password secret exists (per-container, like
  #      vaultwarden's admin token).
  #   2. Upsert the Kanidm OIDC strategy row into `authentication`, reading
  #      the client secret from the shared OAuth2 mount. Done before
  #      /finalize so that the master boot triggered by /finalize calls
  #      activateStrategies() and picks the row up immediately.
  #   3. If the `settings` table is empty (first boot): POST /finalize,
  #      then wait for the master process to come up. Wiki.js self-reboots
  #      into master mode and activates the pre-seeded OIDC strategy — no
  #      extra restart needed.
  #   4. If already provisioned and the OIDC client secret rotated since
  #      the last run: restart wiki-js.service so activateStrategies()
  #      re-reads the updated row.
  #
  # wantedBy + after (NOT partOf/bindsTo) couple this to wiki-js.service: it
  # is pulled in whenever wiki-js starts (so it re-syncs the OIDC row on every
  # restart), but the wiki-js stop phase does NOT tear it down — important
  # because step 4 restarts wiki-js from within this unit, and a bindsTo stop
  # would race the running script. RemainAfterExit is omitted so each start
  # re-runs the oneshot.
  systemd.services.wikijs-provision = {
    description = "Finalize Wiki.js setup and seed Kanidm OIDC strategy";
    wantedBy = [ "wiki-js.service" ];
    after = [ "wiki-js.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Let the oneshot retry on failure during early boot (DB/IdP not yet
      # reachable), mirroring nextcloud-setup-oidc.
      Restart = "on-failure";
      RestartSec = 10;
    };
    path = [ pkgs.coreutils pkgs.curl pkgs.openssl pkgs.postgresql_17 ];
    script = ''
      set -euo pipefail

      dbpw_file=/var/lib/secrets/postgres/wikijs/db-password
      oauth_secret_file=/var/lib/secrets/oauth2/wikijs/secret
      adminpw_dir=/var/lib/secrets/wikijs
      adminpw_file=$adminpw_dir/admin-password
      admin_email="admin@minnecker.com"
      site_url="https://wiki.minnecker.com"

      # --- preflight: shared mounts present ---
      if [ ! -s "$dbpw_file" ]; then
        echo "Error: $dbpw_file missing (shared Postgres mount not attached?)" >&2
        exit 1
      fi
      if [ ! -s "$oauth_secret_file" ]; then
        echo "Error: $oauth_secret_file missing (shared OAuth2 mount not attached?)" >&2
        exit 1
      fi
      dbpw="$(cat "$dbpw_file")"
      client_secret="$(cat "$oauth_secret_file")"

      # --- per-container admin password (generated locally, not shared) ---
      install -d -m 700 "$adminpw_dir"
      if [ ! -s "$adminpw_file" ]; then
        pw="$(openssl rand -base64 32)"
        ( umask 077; printf '%s' "$pw" > "$adminpw_file" )
        chmod 600 "$adminpw_file"
        echo "Generated Wiki.js admin password at $adminpw_file (value not logged)."
      fi
      chmod 600 "$adminpw_file"
      adminpw="$(cat "$adminpw_file")"

      export PGHOST=nixpostgres PGUSER=wikijs PGDATABASE=wikijs
      export PGPASSWORD="$dbpw"
      psql_flags="-v ON_ERROR_STOP=1 -tA"

      # --- wait for wiki-js' setup/master server + DB migrations ---
      # `after wiki-js.service` guarantees the unit is active, but the HTTP
      # listener may take a moment to bind. Poll until :3000 responds.
      for i in $(seq 1 60); do
        if curl -fsS --max-time 3 "http://localhost:3000/" >/dev/null 2>&1; then break; fi
        sleep 2
      done
      # The `authentication`/`settings` tables are created by Knex migrations
      # during wiki-js startup (before the setup server listens), but wait
      # until they actually accept queries to avoid a transient race.
      for i in $(seq 1 60); do
        if psql $psql_flags -c "SELECT 1 FROM authentication LIMIT 1" >/dev/null 2>&1; then break; fi
        sleep 2
      done
      if ! psql $psql_flags -c "SELECT 1 FROM authentication LIMIT 1" >/dev/null 2>&1; then
        echo "Error: authentication table not reachable after 120s" >&2
        exit 1
      fi

      # --- (2) upsert the Kanidm OIDC strategy row ---
      # Row shape mirrors what the `updateStrategies` GraphQL mutation writes
      # (server/graph/resolvers/authentication.js) and the setup wizard's
      # `local` strategy insert. config is plain JSON (the OIDC module reads
      # clientSecret from it directly — no encryption). callbackURL is
      # injected at activation time as <host>/login/<key>/callback, so it
      # is correct once /finalize has set host=$site_url in the settings.
      old_secret="$(psql $psql_flags -c "SELECT config->>'clientSecret' FROM authentication WHERE key='oidc'" 2>/dev/null || true)"
      psql $psql_flags -v secret="$client_secret" <<'SQL' >/dev/null
INSERT INTO authentication (key, "strategyKey", "displayName", "order", "isEnabled", config, "selfRegistration", "domainWhitelist", "autoEnrollGroups")
VALUES (
  'oidc', 'oidc', 'Kanidm SSO', 1, true,
  jsonb_build_object(
    'clientId', 'wikijs',
    'clientSecret', :'secret',
    'authorizationURL', 'https://idm.minnecker.com/oauth2/authorise',
    'tokenURL', 'https://idm.minnecker.com/oauth2/token',
    'userInfoURL', 'https://idm.minnecker.com/oauth2/openid/wikijs/userinfo',
    'skipUserProfile', false,
    'issuer', 'https://idm.minnecker.com/oauth2/openid/wikijs',
    'emailClaim', 'email',
    'displayNameClaim', 'name',
    'pictureClaim', 'picture',
    'mapGroups', false,
    'groupsClaim', 'groups',
    'logoutURL', '',
    'acrValues', ''
  ),
  false,
  jsonb_build_object('v', '[]'::jsonb),
  jsonb_build_object('v', '[]'::jsonb)
)
ON CONFLICT (key) DO UPDATE SET
  "strategyKey" = EXCLUDED."strategyKey",
  "displayName" = EXCLUDED."displayName",
  "isEnabled" = EXCLUDED."isEnabled",
  config = EXCLUDED.config;
SQL

      # --- (3) first boot: drive the setup wizard via POST /finalize ---
      settings_count="$(psql $psql_flags -c "SELECT count(*) FROM settings")"
      if [ "$settings_count" = "0" ]; then
        echo "Settings table empty — driving setup wizard via POST /finalize..."
        # /finalize writes all settings rows, default groups/users/locale,
        # the local auth strategy, RSA certs and sessionSecret, then
        # self-reboots into master mode and calls activateStrategies() —
        # which picks up the OIDC row seeded above. No extra restart needed.
        resp="$(curl -sS --max-time 60 \
          -H 'Content-Type: application/json' \
          -d "{\"adminEmail\":\"$admin_email\",\"adminPassword\":\"$adminpw\",\"siteUrl\":\"$site_url\",\"telemetry\":false}" \
          "http://localhost:3000/finalize" || true)"
        if ! printf '%s' "$resp" | grep -q '"ok":true'; then
          echo "Error: /finalize did not report success: $resp" >&2
          exit 1
        fi
        echo "Setup finalized. Waiting for master process to come up..."
        # wiki-js destroys the setup server and boots master after ~1s.
        for i in $(seq 1 60); do
          if curl -fsS --max-time 3 "http://localhost:3000/" >/dev/null 2>&1; then break; fi
          sleep 2
        done
        echo "Wiki.js bootstrap complete. OIDC strategy active after master boot."
        exit 0
      fi

      # --- (4) subsequent boots: re-activate only if the secret rotated ---
      if [ -n "$old_secret" ] && [ "$old_secret" != "$client_secret" ]; then
        echo "OIDC client secret rotated — restarting wiki-js to re-activate strategies."
        # Restart is the last action: the unit has no partOf/bindsTo, so the
        # wiki-js stop phase does not tear this script down. wiki-js' start
        # phase then pulls this unit again via wantedBy — the re-run finds
        # the secret now in sync and exits cleanly (no loop).
        systemctl restart wiki-js.service
      else
        echo "Wiki.js already provisioned; OIDC strategy in sync. Nothing to do."
      fi
    '';
  };
}
