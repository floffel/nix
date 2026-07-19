{ config, pkgs, lib, ... }:
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    enableTCPIP = true;
    settings.listen_addresses = "127.0.0.1";
    ensureDatabases = [
      "forgejo"
      "vaultwarden"
      "wikijs"
      "matrix"
    ];
    ensureUsers = [
      { name = "forgejo"; ensureDBOwnership = true; }
      { name = "vaultwarden"; ensureDBOwnership = true; }
      { name = "wikijs"; ensureDBOwnership = true; }
      { name = "matrix"; ensureDBOwnership = true; }
    ];
    authentication = lib.mkForce ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
  };
}