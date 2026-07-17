# NixOS Service Configuration for PostgreSQL and Redis cache.
#
# Redis is deployed on nixpostgres alongside PostgreSQL because:
# - It serves both Nextcloud and Roundcube on nixnginx (proxied from localhost)
# - Redis memory cache persists across fail2ban restarts when used as the
#   in-memory ban database backend on nixnginx (via settings.redis-server)
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
      
      host    roundcube       roundcube       10.20.20.1/24          scram-sha-256
      host    nextcloud       nextcloud       10.20.20.1/24          scram-sha-256
      host    forgejo         forgejo         10.20.20.1/24          scram-sha-256
      host    matrix          matrix          10.20.20.1/24          scram-sha-256
      host    vaultwarden     vaultwarden     10.20.20.1/24          scram-sha-256
      host    wikijs          wikijs          10.20.20.1/24          scram-sha-256
      host    roundcube       roundcube       fd01::1/64             scram-sha-256
      host    nextcloud       nextcloud       fd01::1/64             scram-sha-256
      host    forgejo         forgejo         fd01::1/64             scram-sha-256
      host    matrix          matrix          fd01::1/64             scram-sha-256
      host    vaultwarden     vaultwarden     fd01::1/64             scram-sha-256
      host    wikijs          wikijs          fd01::1/64             scram-sha-256
    '';
  };

  # Enable Prometheus PostgreSQL exporter for database performance metrics scraping
  services.prometheus.exporters.postgres = {
    enable = true;
    listenAddress = "[::]";
    port = 9187;
  };

  # Override systemd service user to run as postgres to use peer auth over unix sockets
  systemd.services.prometheus-postgres-exporter.serviceConfig.User = "postgres";

  # Auto-provision each ensureUsers role's password on the shared secrets
  # mount (/var/lib/secrets/postgres/<role>/db-password), which is bind-mounted
  # read-write here and read-only into each consuming container. The file is the
  # sole source of truth: on every run the role's password is re-applied from the
  # file, so Postgres state can never drift from what consumers read. A missing
  # file is generated with a fresh random value before being applied.
  #
  # This removes the manual `ALTER ROLE ... WITH PASSWORD` step and the per
  # consumer `setup-*-secrets.sh` DB-password helpers: consumers read the same
  # file Kanidm-style (single writer, identical file on both sides).
  #
  # partOf + bindsTo couple this oneshot to postgresql.service so it is stopped
  # and re-pulled on every postgres restart; RemainAfterExit is intentionally
  # omitted so the unit re-runs (rather than staying "active (exited)") on each
  # restart, re-applying the file's password to the role.
  systemd.services.postgresql-password-provisioning = {
    description = "Provision PostgreSQL role passwords on the shared secrets mount";
    wantedBy = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
    partOf = [ "postgresql.service" ];
    bindsTo = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      # /var/lib/secrets/postgres is the rw NAS bind mount on this container.
      ReadWritePaths = [ "/var/lib/secrets/postgres" ];
    };
    path = [ config.services.postgresql.package pkgs.util-linux pkgs.coreutils ];
    script = ''
      set -euo pipefail

      # Fail loudly if the shared mount is not attached — otherwise we would
      # silently write passwords to a throwaway rootfs dir, apply them to the
      # roles, and lose them on container restart (consumers would never see
      # the file and could never authenticate).
      mountpoint -q /var/lib/secrets/postgres || {
        echo "Error: /var/lib/secrets/postgres is not a mount point (missing Proxmox bind entry?)" >&2
        exit 1
      }

      # ensureUsers roles are created in a post-start phase of postgresql.service,
      # which `after` does not strictly guarantee has completed. Wait until the
      # server accepts connections before issuing ALTER ROLE.
      for i in {1..30}; do
        if pg_isready -q; then break; fi
        sleep 1
      done
      pg_isready -q || { echo "Error: postgres not ready after 30s" >&2; exit 1; }

      # Single source of truth: derive the role list from ensureUsers so a role
      # added there can never be missed by this provisioning loop.
      ROLES="${lib.concatStringsSep " " (map (u: u.name) config.services.postgresql.ensureUsers)}"
      for role in $ROLES; do
        d="/var/lib/secrets/postgres/$role"
        install -d -m 700 "$d"
        f="$d/db-password"
        if [ ! -s "$f" ]; then
          # 32 random bytes as 64 hex chars (CSPRNG, no extra dependency).
          pw="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
          printf '%s' "$pw" > "$f"
        fi
        chmod 600 "$f"
        # Re-apply from file on every run so Postgres matches the file exactly.
        # Feed the statement via a here-doc so psql's :'pw' quoting works
        # correctly (the -c flag mangles the quoting under shell interpolation).
        # :'pw' makes psql emit the value as a properly-quoted SQL string
        # literal, preventing both SQL injection from a hand-edited file and
        # password leakage via psql error output.
        pw="$(cat "$f")"
        psql -v ON_ERROR_STOP=1 -v role="$role" -v pw="$pw" <<'SQL' >/dev/null
ALTER ROLE :"role" WITH PASSWORD :'pw';
SQL
      done
    '';
  };

  # Redis — shared cache used by Nextcloud (Redis session handler, distributed
  # locking) and fail2ban ban persistence on nixnginx. Listen on the service
  # LAN so all containers can connect; firewall is disabled in LXC mode.

  # Auto-provision the redis nextcloud password on the shared secrets mount,
  # mirroring the postgresql-password-provisioning pattern: a oneshot unit that
  # runs before redis-nextcloud.service, creates the password file on the NAS
  # bind mount if missing, and fails loudly if the mount is absent.
  systemd.services.redis-nextcloud-password-provisioning = {
    description = "Provision Redis nextcloud password on the shared secrets mount";
    wantedBy = [ "redis-nextcloud.service" ];
    before = [ "redis-nextcloud.service" ];
    partOf = [ "redis-nextcloud.service" ];
    bindsTo = [ "redis-nextcloud.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.util-linux pkgs.coreutils ];
    script = ''
      set -euo pipefail

      mountpoint -q /var/lib/secrets/redis || {
        echo "Error: /var/lib/secrets/redis is not a mount point (missing Proxmox bind entry?)" >&2
        exit 1
      }

      install -d -m 700 /var/lib/secrets/redis
      f="/var/lib/secrets/redis/nextcloud-password"
      if [ ! -s "$f" ]; then
        pw="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        printf '%s' "$pw" > "$f"
      fi
      chmod 600 "$f"
    '';
  };

  services.redis.servers.nextcloud = {
    enable = true;
    bind = "*";
    port = 6379;
    save = [[900 1]];
    requirePassFile = "/var/lib/secrets/redis/nextcloud-password";
    extraParams = [
      "--protected-mode" "yes"
      "--maxmemory" "256mb"
      "--maxmemory-policy" "allkeys-lru"
      "--tcp-keepalive" "60"
      "--slowlog-log-slower-than" "5000"
    ];
  };
}