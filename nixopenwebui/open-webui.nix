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
      OPENAI_API_BASE_URL = "http://192.168.1.196:1234/v1";
      OPENAI_API_KEY = "x";
      ENABLE_OLLAMA_API = "False"; # Disable local Ollama since we use remote OpenAI API
    };
  };

  # Load sensitive environment variables (OAUTH_CLIENT_SECRET, OLLAMA_API_BASE_URL) at runtime
  systemd.services.open-webui.serviceConfig.EnvironmentFile = "/var/lib/secrets/open-webui/env";
}
