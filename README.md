# Proxmox NixOS Guest Containers Setup Guide

This repository contains a unified NixOS configuration for running a **Mail Server** and a **WireGuard Gateway** as unprivileged Proxmox LXC containers.

---

## 🚀 Quick Deployment Steps

Clone this repository inside your container (e.g. into `/root/nixos-config`), then run the command block for that specific container.

### 📬 Option A: Setup Mail Server Container
Run these commands inside the Mail Server LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/mail-server/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/mail-server/mail-server.nix /etc/nixos/mail-server.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & DKIM (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 🔑 Option B: Setup WireGuard VPN Container
Run these commands inside the WireGuard LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/wireguard/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 🗄️ Option C: Setup PostgreSQL Database Container
Run these commands inside the PostgreSQL LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/postgresqlng/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Rebuild the system
nixos-rebuild switch
```

---

### 🛡️ Option D: Setup Kanidm Identity Management & SSO Container
Run these commands inside the Kanidm LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/idmng/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & Certificates (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 🦊 Option E: Setup Forgejo Container
Run these commands inside the Forgejo LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/forgejo/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 🚀 Option F: Setup Forgejo Actions Runner Container
Run these commands inside the Forgejo Actions Runner LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/forgejo-runner/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Enable Proxmox features nesting=1 and keyctl=1 on the host for Docker support

# 4. Setup Secrets (see "Required Secrets" section below)

# 5. Rebuild the system
nixos-rebuild switch
```

### 📊 Option G: Setup Monitoring Container (Prometheus, Loki & Grafana)
Run these commands inside the Monitoring LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/monitoringng/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 🤖 Option H: Setup Open WebUI Container
Run these commands inside the Open WebUI LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/openwebuing/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & LLM Connection (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 💬 Option I: Setup Matrix Synapse Container
Run these commands inside the Matrix Synapse LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/matrixng/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & Database Connection (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 🔑 Option J: Setup Vaultwarden Container
Run these commands inside the Vaultwarden LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/vaultwardenng/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & Database Connection (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 📝 Option K: Setup Wiki.js Container
Run these commands inside the Wiki.js LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/wikijsng/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & Database Connection (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 📹 Option L: Setup Jitsi Meet Container
Run these commands inside the Jitsi LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/jitsing/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Rebuild the system
nixos-rebuild switch
```

---

### 🌐 Option M: Setup NSD Authoritative Nameserver Container
Run these commands inside the NSD LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/nsdng/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & TSIG Keys (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

## 🔒 Required Secrets & Prerequisites

Before running `nixos-rebuild switch`, you must place the credentials/keys on each server.
Or in my case, mount it into the secrets stores. Replace type with corresponding type, e.g. mail, wireguard...

Create the directory:
```bash
source /etc/set-environment
mkdir -p /var/lib/secrets/<type> && chmod 700 /var/lib/secrets/<type>
```

Then add the following line to the container config, e.g. `/etc/pve/lxc/<id>.conf`. Get the id by `pct list`.
```
lxc.mount.entry: /mnt/pve/nas/shared/secrets/<type> var/lib/secrets/<type> none bind,rw 0 0
```

### For the Mail Server:
1. **LDAP Secrets**:   
   Ensure correct ownership:
   ```bash
   chown postfix:postfix /var/lib/secrets/mail/*/*.cf
   chown dovecot:dovecot /var/lib/secrets/mail/dovecot/ldap.conf.ext
   chmod 600 /var/lib/secrets/mail/*
   ```

2. **LDAP over SSL (LDAPS) Configuration for Postfix**:
   Since the Postfix LDAP maps are loaded from runtime configuration files (e.g., `/var/lib/secrets/mail/postfix/ldap-recipients.cf`, `ldap-aliases.cf`, `ldap-domains.cf`, and `ldap-senders.cf`), you must configure them to use the secure LDAP server on port 636:
   * Edit each `.cf` file in `/var/lib/secrets/mail/postfix/` and set:
     ```ini
     server_host = ldaps://ldap:636
     tls_require_cert = no
     ```
   * Note: Setting `tls_require_cert = no` tells Postfix's LDAP client to trust the self-signed TLS certificates of the internal container network.

3. **DKIM Keys**:
   ```bash
   chown -R 182:182 /var/lib/secrets/dkim/ # 182 is the rspamd user
   chmod 600 /var/lib/secrets/dkim/*.private
   ```

### For the WireGuard Server:
1. **WireGuard Server Keys**:
   Generate a private and public key pair for the server:
   ```bash
   # Make sure the directory exists and has restricted permissions
   mkdir -p /var/lib/secrets/wireguard && chmod 700 /var/lib/secrets/wireguard
   
   # Generate private key
   nix-shell -p wireguard-tools --run "wg genkey" > /var/lib/secrets/wireguard/private.key
   chmod 600 /var/lib/secrets/wireguard/private.key

   # Generate public key (optional, useful for client configs)
   nix-shell -p wireguard-tools --run "wg pubkey" < /var/lib/secrets/wireguard/private.key > /var/lib/secrets/wireguard/public.key
   ```

2. **WireGuard Client Setup**:
   To connect a client (such as your phone or laptop) to this gateway, you need to set up a key pair on the client and register its public key on the server.
   
   * **Step A: Generate Client Keys**
     Generate a key pair on the client device. If using a command-line client:
     ```bash
     wg genkey | tee client_private.key | wg pubkey > client_public.key
     ```
     For graphical clients (like the iOS/Android WireGuard app), the app can generate these keys for you automatically.
   
   * **Step B: Register the Client's Public Key on the Server**
     Edit the WireGuard configuration file on the server (`/root/nixos-config/wireguard/configuration.nix`) and add the client's public key to the `peers` block:
     ```nix
     wg-quick.interfaces.wg0 = {
       ...
       peers = [
         {
           publicKey = "CLIENT_PUBLIC_KEY_HERE";
           allowedIPs = [ "10.100.0.2/32" ]; # Assign a static IP inside the tunnel to the client
         }
       ];
     };
     ```
     Then, run the rebuild command on the server to apply the configuration change:
     ```bash
     nixos-rebuild switch
     ```
   
   * **Step C: Create the Client Configuration**
     Configure the client device (e.g. in `/etc/wireguard/wg0.conf` or inside the WireGuard app) with:
     ```ini
     [Interface]
     Address = 10.100.0.2/24
     PrivateKey = <CLIENT_PRIVATE_KEY>
     DNS = 1.1.1.1 # Or your local DNS resolver IP
     
     [Peer]
     PublicKey = <SERVER_PUBLIC_KEY> # Get this by running: cat /var/lib/secrets/wireguard/public.key
     Endpoint = <SERVER_IP_OR_DOMAIN>:51820
     AllowedIPs = 0.0.0.0/0 # Or 10.100.0.0/24 to route only VPN traffic
     PersistentKeepalive = 25
     ```

### For the Kanidm Server:
1. **SSL/TLS Certificates**:
   Kanidm requires SSL/TLS certificates to boot and run. Create the secrets directory and place the certificate chain and private key:
   ```bash
   mkdir -p /var/lib/secrets/kanidm/certs && chmod 700 /var/lib/secrets/kanidm && chmod 700 /var/lib/secrets/kanidm/certs
   # Copy your certificates into:
   # /var/lib/secrets/kanidm/certs/idm.crt
   # /var/lib/secrets/kanidm/certs/idm.key
   ```

### For the Forgejo Server:
1. **Database Password**:
   Store the database password that matches the Postgres database connection:
   ```bash
   mkdir -p /var/lib/secrets/forgejo && chmod 700 /var/lib/secrets/forgejo
   echo "your_postgres_db_password" > /var/lib/secrets/forgejo/db-password
   chmod 600 /var/lib/secrets/forgejo/db-password
   chown -R forgejo:forgejo /var/lib/secrets/forgejo
   ```
2. **Kanidm OAuth2/OIDC Client Secret**:
   Store the client secret generated in Kanidm for Forgejo SSO authentication:
   ```bash
   echo "your_forgejo_oauth_secret" > /var/lib/secrets/forgejo/oauth-secret
   chmod 600 /var/lib/secrets/forgejo/oauth-secret
   chown -R forgejo:forgejo /var/lib/secrets/forgejo
   ```

### For the Monitoring Server (Grafana, Prometheus & Loki):
1. **Grafana Credentials, Encryption Key & OAuth Secret**:
   Create the secrets directory and store the admin password, database encryption key, and Kanidm OIDC client secret:
   ```bash
   mkdir -p /var/lib/secrets/grafana && chmod 700 /var/lib/secrets/grafana
   echo "your_grafana_admin_password" > /var/lib/secrets/grafana/admin-password
   # Generate a secure random hex string for Grafana database encryption key
   openssl rand -hex 16 > /var/lib/secrets/grafana/secret-key
   # Store the OIDC client secret generated in Kanidm for Grafana
   echo "your_grafana_oauth_secret" > /var/lib/secrets/grafana/oauth-secret
   chmod 600 /var/lib/secrets/grafana/*
   chown -R grafana:grafana /var/lib/secrets/grafana
   ```

### For the Open WebUI Server:
1. **SSO OAuth Secret & LLM Endpoints**:
   Create the secrets directory and store the environment file containing the OIDC client secret and local LLM endpoints:
   ```bash
   mkdir -p /var/lib/secrets/open-webui && chmod 700 /var/lib/secrets/open-webui
   
   # Write environment file with your LLM configuration
   cat <<EOF > /var/lib/secrets/open-webui/env
   OAUTH_CLIENT_SECRET="your_kanidm_openwebui_oauth_secret"
   
   # Local LLM endpoints (e.g. Ollama or a remote OpenAI-compatible API)
   OLLAMA_API_BASE_URL="http://your_ollama_ip:11434"
   OPENAI_API_BASE_URL="http://your_llm_server_ip:8000/v1"
   OPENAI_API_KEY="your_llm_api_key_if_needed"
   EOF
   
   chmod 600 /var/lib/secrets/open-webui/env
   chown -R 994:994 /var/lib/secrets/open-webui # 994 is the default open-webui system user
   ```

### For the Matrix Synapse Server:
1. **Synapse Database Password and OIDC Secrets**:
   Create the secrets directory and write the YAML configuration file containing the database connection details and the Kanidm OIDC client credentials:
   ```bash
   mkdir -p /var/lib/secrets/matrix && chmod 700 /var/lib/secrets/matrix
   
   # Write synapse secrets configuration
   cat <<EOF > /var/lib/secrets/matrix/secrets.yaml
   database:
     args:
       password: "your_matrix_postgresql_password"

   oidc_providers:
     - idp_id: "kanidm"
       idp_name: "Kanidm SSO"
       issuer: "https://idm.minnecker.com/oauth2/openid/matrix"
       client_id: "matrix"
       client_secret: "your_kanidm_matrix_oauth_secret"
       scopes:
         - "openid"
         - "profile"
         - "email"
       user_mapping_provider:
         config:
           subject_claim: "sub"
           localpart_claim: "preferred_username"
           display_name_claim: "name"
           email_claim: "email"
   EOF
   
   chmod 600 /var/lib/secrets/matrix/secrets.yaml
   chown -R matrix-synapse:matrix-synapse /var/lib/secrets/matrix
   ```

### For the Vaultwarden Server:
1. **SSO / Database Connection and Admin Token**:
   Create the secrets directory and write the environment file containing the PostgreSQL database connection string and your secure admin panel token:
   ```bash
   mkdir -p /var/lib/secrets/vaultwarden && chmod 700 /var/lib/secrets/vaultwarden
   
   # Write environment file with database and admin settings
   cat <<EOF > /var/lib/secrets/vaultwarden/env
   DATABASE_URL="postgresql://vaultwarden:your_vaultwarden_db_password@postgresqlng/vaultwarden"
   
   # Admin panel token (use a secure random string or an Argon2 hash of it)
   # To generate an Argon2 hash: vaultwarden hash
   ADMIN_TOKEN="your_secure_admin_token_or_hash"
   EOF
   
   chmod 600 /var/lib/secrets/vaultwarden/env
   chown -R vaultwarden:vaultwarden /var/lib/secrets/vaultwarden
   ```

### For the Wiki.js Server:
1. **Wiki.js Database Password**:
   Create the secrets directory and write the environment file containing the PostgreSQL database password:
   ```bash
   mkdir -p /var/lib/secrets/wikijs && chmod 700 /var/lib/secrets/wikijs
   
   # Write environment file with database password
   echo 'WIKI_DB_PASS="your_wikijs_db_password"' > /var/lib/secrets/wikijs/env
   
   chmod 600 /var/lib/secrets/wikijs/env
   chown -R wiki-js:wiki-js /var/lib/secrets/wikijs
   ```

### For the Jitsi Meet Server:
1. **Network Port Forwarding (UDP 10000)**:
   For group audio and video calls to function correctly, Jitsi Videobridge (JVB) requires direct UDP connectivity.
   Configure your Proxmox firewall and external router to forward:
   * **UDP Port 10000** -> Point to `172.16.16.20` (the `jitsing` container IP).

### For the NSD Nameserver Server:
1. **TSIG Key Secret**:
   Create the secrets directory and store the base64-encoded secret key used for TSIG-authenticated DNS zone transfers (AXFR) and NOTIFY synchronization with Hetzner:
   ```bash
   mkdir -p /var/lib/secrets/nsd && chmod 700 /var/lib/secrets/nsd
   
   # Write base64 TSIG key (do not include quotes, only the plain secret key string)
   echo "your_base64_tsig_key_secret_here" > /var/lib/secrets/nsd/hetzner-key.key
   
   # Set correct permissions
   chmod 600 /var/lib/secrets/nsd/hetzner-key.key
   chown -R nsd:nsd /var/lib/secrets/nsd
   ```

### For the Forgejo Actions Runner:
1. **Registration Token**:
   Register a runner in your Forgejo web interface (Site Administration -> Actions -> Runners).
   Create the directory and store the registration token in env format:
   ```bash
   mkdir -p /var/lib/secrets/forgejo && chmod 700 /var/lib/secrets/forgejo
   echo 'TOKEN="your_registration_token"' > /var/lib/secrets/forgejo/runner-token
   chmod 600 /var/lib/secrets/forgejo/runner-token
   ```

### 🐳 Proxmox Host Options for Forgejo Actions Runner
Since the runner container runs nested Docker-in-LXC to execute containerized Action steps, you must enable these settings on your Proxmox host:
1. Go to the Proxmox Web UI, select the **Runner Container -> Options -> Features**.
2. Edit the Features and check:
   * **Nesting** (allows running Docker inside the container)
   * **Keyctl** (improves systemd security/user namespace mapping support)
3. Alternatively, via Proxmox Host CLI, edit `/etc/pve/lxc/<id>.conf` and add:
   ```text
   features: nesting=1,keyctl=1
   ```

---

## 🧰 Starting configuration for a new Proxmox LXC container

When you create a new Proxmox container for NixOS, use the following starting configuration as a minimal base. Edit (or create) `/etc/nixos/configuration.nix` inside the container using an editor like `nano` and paste the block below.

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

After saving `/etc/nixos/configuration.nix` (e.g. `sudo nano /etc/nixos/configuration.nix`) run these commands inside the container to load the environment, update channels, and rebuild the system:

```bash
# Load environment variables provided by Proxmox (if present)
source /etc/set-environment

# Update NixOS channels
sudo nix-channel --update

# Rebuild and upgrade the system
sudo nixos-rebuild switch --upgrade
```

Notes:
- Editing via `nano /etc/nixos/configuration.nix` is fine for quick setup; for reproducible deployments prefer managing the configuration from a git checkout and symlinking as shown earlier.
- If your container is unprivileged, some additional tweaks may be needed depending on your Proxmox setup.
