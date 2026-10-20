# NixOS Service Configuration for Open WebUI
{ config, pkgs, lib, ... }:

let
  # Read-only mail tool server provided by nixmail (nixmail/mail-api.py).
  # Access control is enforced by the bridge: it only accepts connections
  # from this container's address and uses the forwarded
  # X-OpenWebUI-User-Email header to select the mailbox. No shared secret
  # is needed, and the model can never choose another user's mailbox.
  mailToolServer = [
    {
      type = "openapi";
      url = "http://10.20.20.13:8081";
      path = "/openapi.json";
      auth_type = "session";
      key = "";
      config = {
        enable = true;
        # Empty access_grants means admin-only in Open WebUI 0.11; grant
        # read access to every signed-in user.
        access_grants = [
          {
            principal_type = "user";
            principal_id = "*";
            permission = "read";
          }
        ];
      };
    }
  ];
in
{
  # Allow unfree packages since NixOS marks Open WebUI's modified license as unfree
  nixpkgs.config.allowUnfree = true;

  services.open-webui = {
    enable = true;
    port = 8080;
    host = "::";
    
    # Configure OAuth/OIDC against Kanidm SSO and link local LLM API
    environment = {
      WEBUI_URL = "https://ai.minnecker.com";
      OPENID_PROVIDER_URL = "https://idm.minnecker.com/oauth2/openid/open-webui/.well-known/openid-configuration";
      OPENID_REDIRECT_URI = "https://ai.minnecker.com/oauth/oidc/callback";
      OAUTH_CLIENT_ID = "open-webui";
      # open-webui is a public PKCE client (no basic secret, see
      # nixidm/kanidm.nix). Open WebUI only registers the OIDC provider when
      # OAUTH_CLIENT_SECRET *or* OAUTH_CODE_CHALLENGE_METHOD is set, so we
      # must set the latter to S256 — otherwise the provider is never
      # registered and the callback 500s.
      OAUTH_CODE_CHALLENGE_METHOD = "S256";
      OAUTH_PROVIDER_NAME = "Kanidm SSO";
      ENABLE_OAUTH_SIGNUP = "True";
      OAUTH_AUTO_REDIRECT = "True";
      ENABLE_SIGNUP = "False"; # Disables open public registration for security hardening
      ENABLE_LOGIN_FORM = "False"; # Hide local username/password login — Kanidm SSO is the only auth path

      # Role mapping from the Kanidm `roles` claim (see nixidm/kanidm.nix
      # claimMaps.roles: open_webui_users -> "user", open_webui_admins /
      # idm_admins -> "admin"). OAUTH_ALLOWED_ROLES gates who may sign in;
      # OAUTH_ADMIN_ROLES grants the Open WebUI admin role. With these set,
      # the first-run "create admin account" prompt is bypassed because the
      # first SSO login auto-provisions the user from the claim rather than
      # from a local signup form.
      OAUTH_ROLES_CLAIM = "roles";
      OAUTH_ALLOWED_ROLES = "user,admin";
      OAUTH_ADMIN_ROLES = "admin";

      # Default connection settings for the local LLM server
      OPENAI_API_BASE_URL = "http://192.168.1.196:8123/v1";
      OPENAI_API_KEY = "x";
      ENABLE_OLLAMA_API = "False"; # Disable local Ollama since we use remote OpenAI API

      # Declarative tool server list (also seeded into the DB by the
      # open-webui-tool-server oneshot for existing installations). The
      # "session" auth type sends the logged-in user's Open WebUI session
      # token; the mail bridge resolves it via /api/v1/auths/ and then
      # impersonates exactly that user's mailbox (read-only).
      TOOL_SERVER_CONNECTIONS = builtins.toJSON mailToolServer;
    };
  };

  # Load sensitive environment variables at runtime. Open WebUI is a public
  # PKCE client against Kanidm (see nixidm/kanidm.nix), so there is NO shared
  # OAuth2 basic secret to pull from a mount — the client id ("open-webui") is
  # all that's required, and it is set declaratively above. Likewise the LLM
  # endpoint (OPENAI_API_BASE_URL / OPENAI_API_KEY) is already declared in
  # `environment`, so this file is only needed for optional runtime overrides.
  # The open-webui-secrets oneshot below provisions it idempotently (empty,
  # correct ownership) so no manual step is required; the leading "-" makes
  # systemd tolerate a missing file as an extra safety net.
  systemd.services.open-webui.serviceConfig.EnvironmentFile = "-/var/lib/secrets/open-webui/env";

  # Provision the env file idempotently on every (re)start of open-webui,
  # mirroring the grafana-secrets / vaultwarden-secrets pattern. The file is
  # intentionally empty: all required config is declarative (OIDC client id,
  # LLM endpoint). It exists solely so the EnvironmentFile directive above has
  # a target and so an operator can drop in overrides (e.g. a different LLM
  # API key) without a rebuild. partOf + bindsTo couple this oneshot to
  # open-webui.service so it re-runs on every (re)start; RemainAfterExit is
  # omitted so each restart re-asserts ownership/permissions.
  #
  # NOTE: services.open-webui uses DynamicUser=true, so there is no persistent
  # "open-webui" system user to chown to (the UID is random per start). This
  # is fine because systemd's EnvironmentFile= is read by the manager (PID 1,
  # root) before exec'ing the service, not by the dynamic user — so a
  # root:root 0600 file is readable by the manager and never exposed to the
  # service's random UID.
  systemd.services.open-webui-secrets = {
    description = "Provision Open WebUI runtime env file (idempotent)";
    wantedBy = [ "open-webui.service" ];
    before = [ "open-webui.service" ];
    partOf = [ "open-webui.service" ];
    bindsTo = [ "open-webui.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      d=/var/lib/secrets/open-webui
      f="$d/env"
      install -d -m 755 -o root -g root "$d"
      # Create the file if it doesn't exist; never overwrite so manual
      # overrides survive restarts.
      if [ ! -e "$f" ]; then
        : > "$f"
      fi
      chown root:root "$f"
      chmod 644 "$f"
    '';
  };

  # Open WebUI persists tool server connections in its config table, so the
  # TOOL_SERVER_CONNECTIONS env var only seeds the value on a fresh install.
  # This oneshot makes the declarative list authoritative on existing
  # installations too. It runs before open-webui starts (SQLite is not
  # locked) and preserves the open-webui ownership of the WAL/SHM files.
  systemd.services.open-webui-tool-server = {
    description = "Upsert declarative Open WebUI tool server connections";
    wantedBy = [ "open-webui.service" ];
    before = [ "open-webui.service" ];
    partOf = [ "open-webui.service" ];
    environment.TOOL_SERVER_CONNECTIONS = builtins.toJSON mailToolServer;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.python3 pkgs.coreutils ];
    script = ''
      set -euo pipefail
      DB=/var/lib/private/open-webui/data/webui.db
      [ -f "$DB" ] || exit 0
      ${pkgs.python3}/bin/python3 - "$DB" <<'PY'
import json
import os
import sqlite3
import sys
import time

db = sys.argv[1]
value = json.loads(os.environ["TOOL_SERVER_CONNECTIONS"])
con = sqlite3.connect(db)
with con:
    con.execute(
        "INSERT INTO config(key, value, updated_at) VALUES('tool_server.connections', ?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        (json.dumps(value), int(time.time())),
    )
PY
      for f in "$DB-wal" "$DB-shm"; do
        if [ -e "$f" ]; then
          chown --reference="$DB" "$f"
        fi
      done
    '';
  };
}
