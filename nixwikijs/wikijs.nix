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
  # wantedBy multi-user.target (NOT wiki-js.service) so the unit runs at every
  # boot regardless of whether wiki-js was (re)started during the rebuild —
  # `wantedBy = wiki-js.service` only fires when wiki-js starts, and if wiki-js
  # was already active when nixos-rebuild applied the new unit, the wants never
  # triggered and the oneshot sat inactive forever (matching the
  # nextcloud-setup-oidc pattern). Readiness is handled by the polling loops
  # below, not by an `after` dependency on wiki-js.service — this avoids the
  # unit being blocked if wiki-js fails to start. No partOf/bindsTo: step 4
  # restarts wiki-js from within this script, and a partOf stop would race it.
  # RemainAfterExit is omitted so each boot re-runs the oneshot.
  systemd.services.wikijs-provision = {
    description = "Finalize Wiki.js setup and seed Kanidm OIDC strategy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    startLimitBurst = 10;
    startLimitIntervalSec = 300;
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
      #
      # Capture whether the row already existed (and its old secret) BEFORE
      # the upsert, so step 4 can decide whether wiki-js needs a restart to
      # re-activate strategies. A newly-inserted row (row_existed=0) always
      # requires a restart; an existing row only if the secret changed.
      row_existed="$(psql $psql_flags -c "SELECT count(*) FROM authentication WHERE key='oidc'" 2>/dev/null || echo 0)"
      old_secret="$(psql $psql_flags -c "SELECT config->>'clientSecret' FROM authentication WHERE key='oidc'" 2>/dev/null || true)"
      # Also capture whether local auth was already disabled, so step 4 can
      # restart wiki-js if it was still enabled (hiding local login).
      local_was_enabled="$(psql $psql_flags -c "SELECT \"isEnabled\" FROM authentication WHERE key='local'" 2>/dev/null || echo "")"
      psql $psql_flags -v secret="$client_secret" <<'SQL' >/dev/null
INSERT INTO authentication (key, "strategyKey", "displayName", "order", "isEnabled", config, "selfRegistration", "domainWhitelist", "autoEnrollGroups")
VALUES (
  'oidc', 'oidc', 'Kanidm SSO', 0, true,
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
    'logoutURL', ''',
    'acrValues', '''
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

      # --- (2b) disable the local auth strategy + enable auto-login ---
      # The setup wizard creates a `local` strategy (admin email/password).
      # Disable it so only "Kanidm SSO" is offered. The local admin account
      # still exists in the DB for emergency access — re-enable the row
      # manually if OIDC is ever unavailable.
      #
      # Also bump local's order above OIDC (order 0): autoLogin's redirect
      # (server/controllers/auth.js) picks `.orderBy('order').first()` without
      # filtering isEnabled, so a disabled local at order 0 would still be
      # selected and (useForm=true) block the auto-redirect to OIDC.
      psql $psql_flags -c "UPDATE authentication SET \"isEnabled\" = false, \"order\" = 1 WHERE key = 'local'" >/dev/null

      # Wiki.js' SPA login page (client/components/login.vue) renders blank
      # with a single non-form strategy: the provider list needs >1 strategy,
      # the form needs useForm=true, and the auto-redirect watcher is gated on
      # useForm. The server-side /login route (server/controllers/auth.js)
      # avoids this entirely when auth.autoLogin is true — it redirects /login
      # to the first non-form strategy before the SPA ever loads. Set it (plus
      # hideLocal, which is the documented companion) declaratively in the
      # settings table so the login page always bounces straight to Kanidm.
      # Rows use the {v: <value>} wrapper that saveToDb writes.
      old_autologin="$(psql $psql_flags -c "SELECT value->>'v' FROM settings WHERE key='auth'" 2>/dev/null | grep -o '"autoLogin":[a-z]*' || true)"
      # The settings.value column is `json` (not jsonb), so cast to jsonb for
      # jsonb_set, then cast the result back to json for assignment.
      psql $psql_flags <<'SQL' >/dev/null
INSERT INTO settings (key, value, "updatedAt") VALUES
  ('auth', '{"v":{"autoLogin":true,"hideLocal":true,"loginBgUrl":"","tokenExpiration":"30m","tokenRenewal":"14d"}}'::json, now())
ON CONFLICT (key) DO UPDATE SET
  value = jsonb_set(jsonb_set(COALESCE(settings.value::jsonb, '{}'::jsonb), '{v,autoLogin}', 'true'::jsonb), '{v,hideLocal}', 'true'::jsonb)::json;
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

      # --- (4) restart wiki-js if the OIDC row was newly created, the
      # client secret rotated, local auth was still enabled (now disabled),
      # or autoLogin was not yet set. On first boot (step 3 above),
      # /finalize's master reboot handles activation so we never reach here.
      new_autologin="$(psql $psql_flags -c "SELECT value->>'v' FROM settings WHERE key='auth'" 2>/dev/null | grep -o '"autoLogin":[a-z]*' || true)"
      if [ "$row_existed" != "1" ] \
         || { [ -n "$old_secret" ] && [ "$old_secret" != "$client_secret" ]; } \
         || [ "$local_was_enabled" = "t" ] \
         || [ "$old_autologin" != '"autoLogin":true' ]; then
        echo "Auth config changed (OIDC row/secret, local disabled, or autoLogin set) — restarting wiki-js to activate."
        # No partOf/bindsTo on this unit, so the wiki-js stop phase does not
        # tear this script down. The unit is wantedBy multi-user.target only,
        # so wiki-js' restart does NOT re-trigger it (no loop).
        systemctl restart wiki-js.service
      else
        echo "Wiki.js already provisioned; OIDC strategy in sync. Nothing to do."
      fi
    '';
  };
}
