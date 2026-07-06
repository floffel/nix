# NixOS Service Configuration for Open WebUI
{ config, pkgs, lib, ... }:

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
      OAUTH_CLIENT_ID = "open-webui";
      OAUTH_PROVIDER_NAME = "Kanidm SSO";
      ENABLE_OAUTH_SIGNUP = "True";
      OAUTH_AUTO_REDIRECT = "True";
      ENABLE_SIGNUP = "False"; # Disables open public registration for security hardening

      # Default connection settings for the local LLM server
      OPENAI_API_BASE_URL = "http://192.168.1.196:52415/v1";
      OPENAI_API_KEY = "x";
      ENABLE_OLLAMA_API = "False"; # Disable local Ollama since we use remote OpenAI API
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
      install -d -m 700 -o root -g root "$d"
      # Create the file if it doesn't exist; never overwrite so manual
      # overrides survive restarts.
      if [ ! -e "$f" ]; then
        : > "$f"
      fi
      chown root:root "$f"
      chmod 600 "$f"
    '';
  };
}
