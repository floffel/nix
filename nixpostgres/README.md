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

### Step 2: Set Database Role Passwords
When PostgreSQL is initialized, NixOS creates the database roles, but they do **not** have passwords configured. Since other services connect remotely over the network using `scram-sha-256` authentication, you must assign secure passwords to each role.

Run the following commands inside your `nixpostgres` container to set the passwords:

```bash
# Enter the PostgreSQL interactive terminal as the admin postgres user
sudo -u postgres psql
```

Inside the `psql` shell, execute the password settings (replace `your_secure_password` with the actual passwords you plan to use in the corresponding service containers):

```sql
ALTER ROLE roundcube WITH PASSWORD 'your_roundcube_db_password';
ALTER ROLE nextcloud WITH PASSWORD 'your_nextcloud_db_password';
ALTER ROLE forgejo WITH PASSWORD 'your_forgejo_db_password';
ALTER ROLE matrix WITH PASSWORD 'your_matrix_db_password';
ALTER ROLE vaultwarden WITH PASSWORD 'your_vaultwarden_db_password';
ALTER ROLE wikijs WITH PASSWORD 'your_wikijs_db_password';

-- Exit the psql terminal
\q
```

---

## 🔒 Security & Client Authentication (`pg_hba.conf`)
*   **Network Listening:** PostgreSQL listens on all interfaces (`*`), but network access is strictly limited by firewalling and host-based validation (`pg_hba.conf`).
*   **Access Control:** The configuration limits database access by source IP and role. For example, the `roundcube` role can only connect to the `roundcube` database from IP addresses inside the private subnet (`172.16.16.0/24` or `fd0c:dead:beef::/64`) using `scram-sha-256` password hashing.
