# NixOS Service Configuration for Vaultwarden
{ config, pkgs, lib, ... }:

{
  services.vaultwarden = {
    enable = true;
    
    # Configure non-sensitive settings declaratively
    config = {
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = 8080;
      
      # Signups disabled by default. Admin can override this or use invitation links.
      SIGNUPS_ALLOWED = false;
      
      # Enable websocket support for real-time client synchronization
      WEBSOCKET_ENABLED = true;
    };

    # Load sensitive data (DATABASE_URL, ADMIN_TOKEN) at startup from runtime environment file
    environmentFile = "/var/lib/secrets/vaultwarden/env";
  };
}
