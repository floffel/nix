# NixOS Service Configuration for Wiki.js
{ config, pkgs, lib, ... }:

{
  services.wiki-js = {
    enable = true;
    
    # Configure settings matching upstream JSON/YAML keys
    settings = {
      port = 3000;
      bindIP = "0.0.0.0";
      db = {
        type = "postgres";
        host = "postgresqlng";
        port = 5432;
        user = "wikijs";
        pass = "$(WIKI_DB_PASS)";
        db = "wikijs";
        ssl = false;
      };
    };

    # Load sensitive environment variables (WIKI_DB_PASS) at startup
    environmentFile = "/var/lib/secrets/wikijs/env";
  };
}
