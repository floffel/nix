# NixOS PostgreSQL Database Server Configuration (`nixpostgres`)

This directory contains the NixOS configuration files for the centralized database container (`nixpostgres`), which runs PostgreSQL 17 to serve backend databases for the other containers in the private network.

---

## 🗄️ Database & User Provisioning

The PostgreSQL service is configured to automatically ensure that the necessary databases and user roles exist with appropriate ownership. 

It provides databases and roles for the following services:
*   `roundcube` (Webmail)
*   `nextcloud` (Cloud storage)
*   `forgejo` (Git service)
*   `matrix` (Chat server)
*   `vaultwarden` (Password manager)
*   `wikijs` (Documentation wiki)

---

## 🚀 Deployment Steps

### Step 1: Initialize the Container configuration
Deploy the files to the `/etc/nixos` directory of your `nixpostgres` container:
```bash
CONTAINER="nixpostgres"

# Clone the repository (if not already done)
git clone https://github.com/floffel/nix.git /root/nixos-config

# Link the configurations
ln -sf /root/nixos-config/$CONTAINER/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix
ln -sf /root/nixos-config/$CONTAINER/postgresql.nix /etc/nixos/postgresql.nix

# Rebuild the system
nixos-rebuild switch
```

### Step 2: Database Role Passwords (auto-provisioned)
Role passwords are **no longer set manually**. The
`postgresql-password-provisioning` unit runs after `postgresql.service` on
every start and writes each role's password to the shared Postgres secrets
mount at `/var/lib/secrets/postgres/<role>/db-password`, then applies it to the
role via `ALTER ROLE ... WITH PASSWORD`. A missing file is generated with a
fresh random value; an existing file is re-applied verbatim (the file is
authoritative — see the root README's "Shared Postgres DB passwords" section).

Consuming containers bind-mount their own `<role>` subdirectory read-only and
read the password from the same file, so the password can never drift between
Postgres and the consumer. No `psql` / `ALTER ROLE` step and no per-container
`setup-*-secrets.sh` DB-password helper is required.

---

## 🔒 Security & Client Authentication (`pg_hba.conf`)
*   **Network Listening:** PostgreSQL listens on all interfaces (`*`), but network access is strictly limited by firewalling and host-based validation (`pg_hba.conf`).
*   **Access Control:** The configuration limits database access by source IP and role. For example, the `roundcube` role can only connect to the `roundcube` database from IP addresses inside the private subnet (`172.16.16.0/24` or `fd0c:dead:beef::/64`) using `scram-sha-256` password hashing.
