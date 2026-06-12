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
*   `/var/lib/secrets/nginx/ldap.conf`: The LDAP server configuration blocks, including the bindDN and bind password:
    ```nginx
    ldap_server mail_users {
      url "ldaps://ldap:636/ou=users,dc=minnecker,dc=com?mail?sub?(employeeType=email)";
      binddn "cn=manager,dc=minnecker,dc=com";
      binddn_passwd "your_ldap_bind_password";
      require valid_user;
    }
    ```

### 3. DH Parameters
*   `/var/lib/secrets/nginx/dh.param`: The Diffie-Hellman parameters file (copied from `/etc/nginx/dh.param`).

### 4. Roundcube Secrets
*   `/var/lib/secrets/nginx/roundcube-db-password.txt`: Contains the plain database password for the PostgreSQL database (`your_roundcube_db_password`).
*   `/var/lib/secrets/nginx/roundcube-des-key.txt`: Contains the 24-character session encryption key (`your_roundcube_des_key`).

### 5. Nextcloud & OIDC Secrets
*   `/var/lib/secrets/nginx/nextcloud-db-password.txt`: Contains the plain database password for the Nextcloud PostgreSQL database.
*   `/var/lib/secrets/nginx/nextcloud-admin-password.txt`: Contains the admin user password for Nextcloud.
*   `/var/lib/secrets/nginx/nextcloud-oauth-secret`: Contains the client secret generated in Kanidm for Nextcloud OIDC (SSO) authentication.

---

## Proxmox LXC Bind Mount Configuration

You can mount these directories from the Proxmox host by adding mount points (`mp`) to the container's configuration file (e.g. `/etc/pve/lxc/<VMID>.conf` on the host).

For example:
```ini
# Mount point for the shared SSL certificates (keep read-only for security)
mp0: /mnt/pve/nas/shared/secrets/ssl,mp=/var/lib/secrets/ssl,ro=1

# Mount point for Nginx-specific secrets (keep read-only for security)
mp1: /tank/secrets/nixnginx,mp=/var/lib/secrets/nginx,ro=1

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
