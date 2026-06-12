# NixOS Service Configuration for PostgreSQL
{ config, pkgs, lib, ... }:

{
  services.postgresql = {
    enable = true;
    
    # Use PostgreSQL version 17
    package = pkgs.postgresql_17;

    # Listen on all network interfaces to allow connections from other containers
    enableTCPIP = true;
    settings = {
      listen_addresses = "*";
    };

    # Automatically ensure the databases exist
    ensureDatabases = [
      "roundcube"
      "nextcloud"
      "forgejo"
      "matrix"
      "vaultwarden"
      "wikijs"
    ];

    # Automatically ensure users exist and own their respective databases
    ensureUsers = [
      {
        name = "roundcube";
        ensureDBOwnership = true;
      }
      {
        name = "nextcloud";
        ensureDBOwnership = true;
      }
      {
        name = "forgejo";
        ensureDBOwnership = true;
      }
      {
        name = "matrix";
        ensureDBOwnership = true;
      }
      {
        name = "vaultwarden";
        ensureDBOwnership = true;
      }
      {
        name = "wikijs";
        ensureDBOwnership = true;
      }
    ];

    # Client authentication rules (pg_hba.conf)
    # Allow local peer/scram authentication and scram connections from private subnet containers.
    authentication = lib.mkForce ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      
      # "local" is for Unix domain socket connections only
      local   all             all                                     peer
      
      # IPv4 local connections:
      host    all             all             127.0.0.1/32            scram-sha-256
      
      # IPv6 local connections:
      host    all             all             ::1/128                 scram-sha-256
 
      # Allow connections from containers in the private network subnets:
      host    roundcube       roundcube       172.16.16.0/24          scram-sha-256
      host    nextcloud       nextcloud       172.16.16.0/24          scram-sha-256
      host    forgejo         forgejo         172.16.16.0/24          scram-sha-256
      host    matrix          matrix          172.16.16.0/24          scram-sha-256
      host    vaultwarden     vaultwarden     172.16.16.0/24          scram-sha-256
      host    wikijs          wikijs          172.16.16.0/24          scram-sha-256
      host    roundcube       roundcube       fd0c:dead:beef::/64     scram-sha-256
      host    nextcloud       nextcloud       fd0c:dead:beef::/64     scram-sha-256
      host    forgejo         forgejo         fd0c:dead:beef::/64     scram-sha-256
      host    matrix          matrix          fd0c:dead:beef::/64     scram-sha-256
      host    vaultwarden     vaultwarden     fd0c:dead:beef::/64     scram-sha-256
      host    wikijs          wikijs          fd0c:dead:beef::/64     scram-sha-256
    '';
  };

  # Enable Prometheus PostgreSQL exporter for database performance metrics scraping
  services.prometheus.exporters.postgres = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 9187;
  };

  # Override systemd service user to run as postgres to use peer auth over unix sockets
  systemd.services.prometheus-postgres-exporter.serviceConfig.User = "postgres";
}
