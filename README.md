# Proxmox NixOS Guest Containers Setup Guide

This repository contains a unified NixOS configuration for running services (such as a mail server, database, LDAP directory, monitoring stack, etc.) as unprivileged Proxmox LXC containers.

---

## 🧰 1. Starting Configuration for a New Proxmox LXC Container

When you create a new Proxmox container for NixOS, use the following starting configuration as a minimal base. Edit (or create) `/etc/nixos/configuration.nix` inside the container and paste the block below.

```nix
{ config, modulesPath, pkgs, lib, ... }:
{
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];
  nix.settings = { sandbox = false; };  
  boot.isContainer = true;
  # Suppress systemd units that are not permitted in unprivileged LXCs
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];
  proxmoxLXC = {
    manageNetwork = false;
    privileged = true;
  };
  services.fstrim.enable = false; # Let Proxmox host handle fstrim
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
        PermitRootLogin = "yes";
        PasswordAuthentication = true;
        PermitEmptyPasswords = "yes";
    };
  };

  environment.systemPackages = with pkgs; [
    git
  ];

  system.stateVersion = "26.05";
}
```

After saving `/etc/nixos/configuration.nix`, run these commands inside the container to load the environment, update channels, and rebuild the system:

```bash
# Load environment variables provided by Proxmox (if present)
source /etc/set-environment

# Update NixOS channels
sudo nix-channel --update

# Rebuild and upgrade the system
sudo nixos-rebuild switch --upgrade
```

---

## 🚀 2. Deploying Git Configurations (Consolidated Flow)

Once the container is running and NixOS is initialized, the configuration is managed via this Git repository. 

To deploy any of the container configurations, run the following unified command sequence inside the container:

```bash
# 1. Set the target container name (change this to your target, e.g. nixnginx, nixnsd, nixpostgres, nixvpn, nixmail, etc.)
CONTAINER="nixnginx"

# 2. Clone the repository (if not already done)
git clone https://github.com/floffel/nix.git /root/nixos-config

# 3. Link the configuration files
ln -sf /root/nixos-config/$CONTAINER/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 4. Link the extra mail module (nixmail only)
if [ "$CONTAINER" = "nixmail" ]; then
  ln -sf /root/nixos-config/nixmail/nixmail.nix /etc/nixos/nixmail.nix
fi

# 5. Apply any container-specific files/steps or mount secrets (see sections below)

# 6. Rebuild the system
nixos-rebuild switch
```

### 📋 Container Names and Specific Setup Steps
The deployment process is identical for all containers, with the following exceptions:

*   **`nixmail` (Mail Server)**: Automatically handles linking the extra `nixmail.nix` module if the `CONTAINER` variable is set to `"nixmail"` in the script above.
*   **`nixvpn` (WireGuard Gateway)**: Requires installing `wireguard-tools` to generate keys and setting up client configs (see below).
*   **`nixforgejo-runner` (Forgejo Runner)**: Requires Nesting and Keyctl options enabled in the Proxmox Web UI (Options -> Features) to run nested Docker containers.

---

## 🔒 3. Required Secrets & Prerequisites

Before running `nixos-rebuild switch`, you must place the credentials/keys on each server or mount a shared secrets store.

### Mounting Secrets via Proxmox Host
To mount secrets dynamically from a central store (e.g. NFS/NAS share), edit the container's configuration file on the Proxmox host (`/etc/pve/lxc/<id>.conf`). 

For example, to mount secrets for the `nixnsd` container:
```text
lxc.mount.entry: /mnt/pve/nas/shared/secrets/nsd var/lib/secrets/nsd none bind,rw 0 0
```

#### Mapping Table:
| Container Name | Host Secret Path (`<type>`) | Container Mount Destination |
| :--- | :--- | :--- |
| `nixmail` | `/mnt/pve/nas/shared/secrets/mail` | `var/lib/secrets/mail` |
| `nixvpn` | `/mnt/pve/nas/shared/secrets/wireguard` | `var/lib/secrets/nixvpn` |
| `nixidm` | `/mnt/pve/nas/shared/secrets/kanidm` | `var/lib/secrets/kanidm` |
| `nixforgejo` | `/mnt/pve/nas/shared/secrets/forgejo` | `var/lib/secrets/forgejo` |
| `nixmonitoring` | `/mnt/pve/nas/shared/secrets/grafana` | `var/lib/secrets/grafana` |
| `nixopenwebui` | `/mnt/pve/nas/shared/secrets/open-webui` | `var/lib/secrets/open-webui` |
| `nixmatrix` | `/mnt/pve/nas/shared/secrets/matrix` | `var/lib/secrets/matrix` |
| `nixvaultwarden` | `/mnt/pve/nas/shared/secrets/vaultwarden` | `var/lib/secrets/vaultwarden` |
| `nixwikijs` | `/mnt/pve/nas/shared/secrets/wikijs` | `var/lib/secrets/wikijs` |
| `nixnsd` | `/mnt/pve/nas/shared/secrets/nsd` | `var/lib/secrets/nsd` |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/nginx` | `var/lib/secrets/nginx` |

On the guest container, create the local mount point directory by setting a variable first:
```bash
# Set target secret folder name (e.g. nsd, mail, wireguard, grafana, etc.)
SECRET_TYPE="nsd"

# Create directory with restricted permissions
source /etc/set-environment
mkdir -p /var/lib/secrets/$SECRET_TYPE && chmod 700 /var/lib/secrets/$SECRET_TYPE
```

---

### Container-Specific Secrets & Configurations

Below are the key files and credentials required per container:

#### 📬 nixmail (Mail Server)
1. **LDAP Secrets**: Ensure correct ownership and read permissions:
   ```bash
   chown postfix:postfix /var/lib/secrets/mail/*/*.cf
   chown dovecot:dovecot /var/lib/secrets/mail/dovecot/ldap.conf.ext
   chmod 600 /var/lib/secrets/mail/*
   ```
2. **LDAPS Connection**: Edit each `.cf` file in `/var/lib/secrets/mail/postfix/` to use secure LDAPS:
   ```ini
   server_host = ldaps://ldap:636
   tls_require_cert = no
   ```
3. **DKIM Keys**: Store DKIM private keys in `/var/lib/secrets/dkim/` with correct ownership for rspamd:
   ```bash
   chown -R 182:182 /var/lib/secrets/dkim/ # 182 is the rspamd user
   chmod 600 /var/lib/secrets/dkim/*.private
   ```

#### 🔑 nixvpn (WireGuard Server)
1. **Server Keys**: Generate the WireGuard server keys:
   ```bash
   mkdir -p /var/lib/secrets/nixvpn && chmod 700 /var/lib/secrets/nixvpn
   nix-shell -p wireguard-tools --run "wg genkey" > /var/lib/secrets/nixvpn/private.key
   chmod 600 /var/lib/secrets/nixvpn/private.key
   nix-shell -p wireguard-tools --run "wg pubkey" < /var/lib/secrets/nixvpn/private.key > /var/lib/secrets/nixvpn/public.key
   ```
2. **Client Setup**: Edit the `peers` block inside `nixvpn/configuration.nix` with the client's public key. On the client device (e.g. `/etc/wireguard/wg0.conf`), set `DNS = 172.16.16.91` (the local Unbound IP) and configure `AllowedIPs` as desired (e.g. `0.0.0.0/0` or `172.16.16.0/24`).
3. **Advanced Routing (Site-to-Site)**: If routing home network traffic (e.g., `192.168.1.0/24`) via a home gateway peer (IP `10.100.0.3`):
   * On the **Server**, add the home subnet to the Home Gateway peer:
     ```nix
     {
       publicKey = "HOME_GATEWAY_PUBLIC_KEY";
       allowedIPs = [ "10.100.0.3/32" "192.168.1.0/24" ];
     }
     ```
   * On the **Mobile Client**, include the home subnet in the client's `AllowedIPs`:
     `AllowedIPs = 10.100.0.0/24, 172.16.16.0/24, 192.168.1.0/24`

#### 🛡️ nixidm (Kanidm Identity Management)
* **SSL/TLS Certificates**: Kanidm requires valid SSL certificates to boot. Place the chain and private key under:
  `/var/lib/secrets/kanidm/certs/idm.crt` and `/var/lib/secrets/kanidm/certs/idm.key`.

#### 🦊 nixforgejo (Forgejo Git Service)
1. **Database Password**: Write the Postgres database password to `/var/lib/secrets/forgejo/db-password` (owned by `forgejo:forgejo`, `chmod 600`).
2. **Kanidm OAuth2/OIDC Secret**: Write the SSO secret to `/var/lib/secrets/forgejo/oauth-secret` (owned by `forgejo:forgejo`, `chmod 600`).

#### 📊 nixmonitoring (Grafana, Prometheus & Loki)
* **Grafana Configuration**: Write credentials and OAuth2 SSO secrets to:
  * `/var/lib/secrets/grafana/admin-password` (admin UI password)
  * `/var/lib/secrets/grafana/secret-key` (used for database encryption, generate via `openssl rand -hex 16`)
  * `/var/lib/secrets/grafana/oauth-secret` (Kanidm OIDC client secret)
  * Ensure all are owned by `grafana:grafana` and set to `chmod 600`.

#### 🤖 nixopenwebui (Open WebUI)
* **SSO & LLM Configuration**: Write the environment file `/var/lib/secrets/open-webui/env` (owned by user `994:994`, `chmod 600`) containing OIDC client secrets and LLM backend URLs:
  ```env
  OAUTH_CLIENT_SECRET="your_kanidm_openwebui_oauth_secret"
  OLLAMA_API_BASE_URL="http://your_ollama_ip:11434"
  OPENAI_API_BASE_URL="http://your_llm_server_ip:8000/v1"
  OPENAI_API_KEY="your_llm_api_key_if_needed"
  ```

#### 💬 nixmatrix (Matrix Synapse)
* **Synapse Configuration**: Write the YAML configuration `/var/lib/secrets/matrix/secrets.yaml` (owned by `matrix-synapse:matrix-synapse`, `chmod 600`) containing the database password and Kanidm OIDC client secret:
  ```yaml
  database:
    args:
      password: "your_matrix_postgresql_password"
  oidc_providers:
    - idp_id: "kanidm"
      idp_name: "Kanidm SSO"
      issuer: "https://idm.minnecker.com/oauth2/openid/matrix"
      client_id: "matrix"
      client_secret: "your_kanidm_matrix_oauth_secret"
      scopes: ["openid", "profile", "email"]
      user_mapping_provider:
        config:
          subject_claim: "sub"
          localpart_claim: "preferred_username"
          display_name_claim: "name"
          email_claim: "email"
  ```

#### 🔑 nixvaultwarden (Vaultwarden)
* **Database & Admin Token**: Write `/var/lib/secrets/vaultwarden/env` (owned by `vaultwarden:vaultwarden`, `chmod 600`):
  ```env
  DATABASE_URL="postgresql://vaultwarden:your_vaultwarden_db_password@nixpostgres/vaultwarden"
  ADMIN_TOKEN="your_secure_admin_token_or_hash" # Generate hash with: vaultwarden hash
  ```

#### 📝 nixwikijs (Wiki.js)
* **Database Password**: Write `/var/lib/secrets/wikijs/env` (owned by `wiki-js:wiki-js`, `chmod 600`):
  ```env
  WIKI_DB_PASS="your_wikijs_db_password"
  ```

#### 📹 nixjitsi (Jitsi Meet)
* **Port Forwarding**: Forward external **UDP port 10000** on your router to the `nixjitsi` container IP (`172.16.16.20`) to allow group video bridge audio/video data.

#### 🌐 nixnsd (NSD Authoritative Nameserver)
* **TSIG Key**: Write the base64-encoded secondary sync TSIG transfer key to `/var/lib/secrets/nsd/sync.key` (owned by `nsd:nsd`, `chmod 600`).

#### 🚀 nixforgejo-runner (Forgejo Actions Runner)
* **Registration Token**: Write `/var/lib/secrets/forgejo/runner-token` (chmod 600):
  ```env
  TOKEN="your_registration_token"
  ```

#### 🕸️ nixnginx (Nginx Reverse Proxy)
* Refer to the specific [nixnginx/README.md](file:///root/nixos-config/nixnginx/README.md) for detailed credentials and configuration specifications for SSL certificates, Nextcloud database credentials, and Roundcube secrets.
