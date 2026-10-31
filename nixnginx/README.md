# NixOS Migration Configuration for Nginx and Roundcube (`nixnginx`)

This directory contains the NixOS configuration files to migrate the Nginx reverse proxy server (which hosts Roundcube webmail, static websites, and proxies various internal services) from the original Arch Linux setup to a NixOS LXC container on Proxmox.

## Directory Structure

*   [`configuration.nix`](file:///root/nix/nixnginx/configuration.nix): The main NixOS entry point, defining hostname and network configuration.
*   [`nginx.nix`](file:///root/nix/nixnginx/nginx.nix): The service definition file containing the custom Nginx build (with NJS, Brotli, and LDAP), virtual hosts, upstreams, mail proxy block, and the Roundcube webmail configuration.
*   [`auth.js`](file:///root/nix/nixnginx/auth.js): The Nginx JavaScript (njs) authentication script copied from `/etc/nginx/njs/auth.js`.

---

## Secrets Mounting Setup

To ensure no secret keys or passwords end up in the world-readable Nix store (`/nix/store`), all secrets are loaded dynamically at runtime. 

*   **SSL Certificates and Keys**: Mounted at `/var/lib/secrets/ssl/` (shared with other containers like `nixnsd` and `nixidm`).
    *   `/var/lib/secrets/ssl/minnecker.com/fullchain.pem`
    *   `/var/lib/secrets/ssl/minnecker.com/key.pem`
    *   `/var/lib/secrets/ssl/substitution.art/fullchain.pem`
    *   `/var/lib/secrets/ssl/substitution.art/key.pem`

*   **Nginx-Specific Secrets**: Placed or mounted in `/var/lib/secrets/nginx/` inside the container:

### 2. LDAP Configuration
*   `/var/lib/secrets/mail/ldap/nginx-ldap.conf`: The LDAP server configuration block, including the bindDN and API token password. This file is **auto-generated** by nixidm's `kanidm-mail-token` service on every Kanidm start and shared via the isolated read-only `mail/ldap` secrets mount (a subdir of the mail secrets, so nixnginx never sees DKIM/Dovecot/Postfix secrets). No manual setup is required. See the root README's "Shared mail LDAP token" section for details.

### 3. DH Parameters
*   `/var/lib/secrets/nginx/dh.param`: The Diffie-Hellman parameters file (copied from `/etc/nginx/dh.param`).

### 4. Roundcube Secrets
* `/var/lib/secrets/postgres/roundcube/db-password`: The plain database password for the PostgreSQL `roundcube` role. This is the **shared Postgres secrets mount** (bind-mounted read-only from the NAS, provisioned on `nixpostgres`) — no local copy is needed. The `.pgpass` file is generated automatically from this file by the `roundcube-setup` `preStart` hook on every start.
* `/var/lib/secrets/nginx/roundcube-des-key.txt`: Contains the 24-character session encryption key (`your_roundcube_des_key`).

### 5. Nextcloud & OIDC Secrets
* `/var/lib/secrets/postgres/nextcloud/db-password`: The plain database password for the Nextcloud PostgreSQL role. This is the **shared Postgres secrets mount** (bind-mounted read-only from the NAS, provisioned on `nixpostgres`) — no local copy is needed.
* `/var/lib/secrets/nginx/nextcloud-admin-password.txt`: Contains the admin user password for Nextcloud.
* `/var/lib/secrets/oauth2/nextcloud/secret`: Contains the client secret for Nextcloud OIDC (SSO). This is the **shared OAuth2 secrets mount** (bind-mounted read-only from the NAS, provisioned on `nixidm`) — no local copy is needed. See the root README's "Shared OAuth2 client secrets" section for the Proxmox mount entry.

### 6. Nextcloud OIDC Client Registration in Kanidm
The Nextcloud OAuth2/OIDC client (`nextcloud`), its `nextcloud_users`
authorization group, scope maps and admin claim are **declared provisioned** in
[`nixidm/kanidm.nix`](../nixidm/kanidm.nix) and reconciled automatically on
each Kanidm start — you no longer create them by hand. The client secret lives
in the shared OAuth2 secrets mount at
`/var/lib/secrets/oauth2/nextcloud/secret` (populate it once on `nixidm`, see
the `nixidm` README). The same file is bind-mounted read-only into `nixnginx`,
so no manual copy is needed.

To grant a user access to Nextcloud, add them to the provisioned group:
```bash
kanidm -D idm_admin group add-members nextcloud_users <username>
```

---

## Proxmox LXC Bind Mount Configuration

You can mount these directories from the Proxmox host by adding mount points (`mp`) to the container's configuration file (e.g. `/etc/pve/lxc/<VMID>.conf` on the host).

For example:
```ini
# Mount point for the shared SSL certificates (keep read-only for security)
mp0: /mnt/pve/nas/shared/secrets/ssl,mp=/var/lib/secrets/ssl,ro=1

# Mount point for Nginx-specific secrets (keep read-only for security)
mp1: /tank/secrets/nixnginx,mp=/var/lib/secrets/nginx,ro=1

# Mount point for the shared Nextcloud OAuth2 client secret (read-only)
mp3: /mnt/pve/nas/shared/secrets/oauth2/nextcloud,mp=/var/lib/secrets/oauth2/nextcloud,ro=1

# Mount points for the shared Postgres DB passwords (read-only)
mp4: /mnt/pve/nas/shared/secrets/postgres/roundcube,mp=/var/lib/secrets/postgres/roundcube,ro=1
mp5: /mnt/pve/nas/shared/secrets/postgres/nextcloud,mp=/var/lib/secrets/postgres/nextcloud,ro=1

# Mount point for Nextcloud user data directory (read-write, NFS backed)
mp6: /mnt/pve/nas/shared/nextcloud-data,mp=/var/lib/nextcloud-data

# Mount point for the static web applications
mp2: /tank/webapps,mp=/usr/share/webapps,ro=1
```

---

## Static Web Application Directories
The Nginx virtual hosts point to static assets in the following paths which must be populated/mounted:
*   `/usr/share/webapps/substitution.art/htdocs/app/web/`
*   `/usr/share/webapps/substitution.art/htdocs/www/`
*   `/usr/share/webapps/bau.minnecker.com/Hausbau-MinneckerWebsite`
*   `/usr/share/webapps/www.minnecker.com`
*   `/usr/share/webapps/element/`
*   `/usr/share/webapps/localhost/htdocs`

---

## Custom Nginx Module Build
Nginx is compiled with standard NJS and Brotli modules, as well as the third-party `kvspb/nginx-auth-ldap` module.

A placeholder `sha256` hash is configured for `nginx-auth-ldap` in `nginx.nix`. When you run your first `nixos-rebuild switch`, the build will halt with a hash mismatch error showing the actual SHA-256 hash. Copy the actual hash and paste it in `nginx.nix` to complete the rebuild.

---

## Rate Limiting
`nginx.nix` keeps one broad per-client flood guard in `commonHttpConfig` (the `http` block), so it applies to **every** vhost. Authentication brute force is CrowdSec's job; these limits only stop floods.

```nginx
map $uri $web_limit_key     { default $binary_remote_addr; "~^/_matrix/(client/v1/media|media)/" ""; }
map $uri $matrix_limit_key  { default "";                  "~^/_matrix/(client/v1/media|media)/" $binary_remote_addr; }

limit_req  zone=web          burst=60  nodelay;   # 30 r/s
limit_req  zone=matrix_media burst=300 nodelay;   # 300 r/s
limit_conn addr 40;
limit_conn matrix_media_conn 200;
```

* **Why two buckets.** An empty limit key means "do not limit this request", so the two maps partition traffic by URI: Matrix media traffic is counted only in the matrix bucket, everything else only in `web`/`addr`. Element Web renders authenticated media (MSC3916) through its service worker, which fetches dozens of `/_matrix/client/v1/media/…` objects in parallel for a single room, and `limit_conn addr` counts **concurrent connections per client across all vhosts on this IP** — one browser hitting Nextcloud, Git, Matrix, Vaultwarden, Wiki and the long-polling `/sync` easily exceeds 40. On 2026-10-31 that showed up as `429` (`limiting requests … zone "web"`) and `503` (`limiting connections by zone "addr"`) on those exact requests, which Element reports as "Fehler beim Herunterladen des Bildes". Media uploads share the matrix bucket; they are authenticated and bounded by `client_max_body_size`.
* **The guard is unchanged for everything else** — scanners are still rejected with the same 40-connection / 30 r/s budget (`205.169.39.18` and friends hit it daily).
* **`limit_req` runs in the PREACCESS phase, `return` in REWRITE.** A `location` that answers with `return 200 …` (the `.well-known` stubs here) never reaches the limit checks, so such locations cannot be used to demonstrate limiting.
* **Verify without touching production traffic.** Spin up a throwaway instance that reuses the exact generated block; `try_files` (not `return`) is required so the requests reach the limit phase:
  ```bash
  CONF=$(grep -oE '/nix/store/[^ ]+-nginx\.conf' /etc/systemd/system/nginx.service | head -1)
  mkdir -p /tmp/lt/logs /tmp/lt/html && printf 'ok\n' > /tmp/lt/html/index.html
  { echo 'worker_processes 1;'; echo 'pid /tmp/lt/pid;'
    echo 'error_log /tmp/lt/logs/error.log info;'
    echo 'events { worker_connections 1024; }'; echo 'http {'
    echo 'access_log off;'; echo 'default_type text/plain;'
    awk '/map \$uri \$web_limit_key/,/limit_req_status/' "$CONF"
    echo 'server { listen 127.0.0.1:18900; root /tmp/lt/html; location / { try_files $uri =404; } }'
    echo '}'; } > /tmp/lt/nginx.conf
  nginx -p /tmp/lt -c /tmp/lt/nginx.conf           # start
  seq 1 300 | xargs -P40 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
    http://127.0.0.1:18900/index.html | sort | uniq -c   # expect ~88x200 + 212x429
  nginx -p /tmp/lt -c /tmp/lt/nginx.conf -s stop; rm -rf /tmp/lt
  ```
  Repeat the last `curl` line against a `/_matrix/client/v1/media/…` path (create the file under `/tmp/lt/html` first): it must return `200` for all 300.
* **Check the live guard**: `journalctl -u nginx | grep -E 'limiting (requests|connections)'` — the log line names the zone, so it also tells you which bucket a client exhausted.

---

## Troubleshooting Setup Failures

### 1. Nextcloud "Command 'upgrade' is not defined"
If the initial Nextcloud setup fails due to database errors, it leaves behind a partial `config.php` file. This tells the NixOS activator that Nextcloud is already installed and to run `upgrade`, which then fails.

To force Nextcloud to perform a clean reinstallation:
1. Delete the partial `config.php` file inside the `nixnginx` container:
   ```bash
   rm -f /var/lib/nextcloud/config/config.php
   ```
2. Reset the Nextcloud database on `nixpostgres` to clear half-written tables (see below).
3. Run `nixos-rebuild switch` again.

### 2. Resetting/Recreating databases (Clean Slate)
To start with a clean database for both Roundcube and Nextcloud, run the following commands on the `nixpostgres` container as root:
```bash
sudo -u postgres psql -c "DROP DATABASE IF EXISTS nextcloud;"
sudo -u postgres psql -c "CREATE DATABASE nextcloud OWNER nextcloud;"

sudo -u postgres psql -c "DROP DATABASE IF EXISTS roundcube;"
sudo -u postgres psql -c "CREATE DATABASE roundcube OWNER roundcube;"
```
