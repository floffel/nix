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
*   **`nixforgejo-runner` (Forgejo Runner)**: Requires Nesting and Keyctl options enabled in the Proxmox Web UI (Options -> Features) to run nested Docker containers. For CI VM integration tests (`just test-vm`), also enable `/dev/kvm` passthrough by adding to `/etc/pve/lxc/<id>.conf`:
  ```ini
  lxc.cgroup2.devices.allow: c 10:232 rwm
  lxc.mount.entry: /dev/kvm dev/kvm none bind,optional,create=file
  ```

---

## 🔒 3. Required Secrets & Prerequisites

Before running `nixos-rebuild switch`, you must place the credentials/keys on each server or mount a shared secrets store.

### Mounting Secrets via Proxmox Host
To mount secrets dynamically from a central store (e.g. NFS/NAS share), edit the container's configuration file on the Proxmox host (`/etc/pve/lxc/<id>.conf`). 

For example, to mount secrets for the `nixnsd` container:
```text
lxc.mount.entry: /mnt/pve/nas/shared/secrets/nsd var/lib/secrets/nsd none bind,rw 0 0
```

#### Complete Bind-Mount Table

Add one `lxc.mount.entry` line per row to the container listed in the first
column. The `Mode` column indicates whether the mount is read-write (`rw`) or
read-only (`ro`). Shared mounts (SSL certificates, OAuth2 client secrets) are
bind-mounted into **multiple** containers from the same NAS path.

| Container | NAS Host Path | Container Mount Dest | Mode | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `nixnsd` | `/mnt/pve/nas/shared/secrets/ssl` | `var/lib/secrets/ssl` | `rw` | ACME writes wildcard certs here (DNS-01) |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/ssl` | `var/lib/secrets/ssl` | `ro` | Reads TLS certs for reverse-proxy vhosts |
| `nixidm` | `/mnt/pve/nas/shared/secrets/ssl` | `var/lib/secrets/ssl` | `ro` | Reads TLS certs for the Kanidm server |
| `nixmail` | `/mnt/pve/nas/shared/secrets/ssl` | `var/lib/secrets/ssl` | `ro` | Reads TLS certs for direct IMAP/SMTP TLS (Dovecot + Postfix) |
| `nixidm` | `/mnt/pve/nas/shared/secrets/mail/ldap` | `var/lib/secrets/mail/ldap` | `rw` | Provisions mail LDAP API token + nginx ldap.conf (sole writer, isolated subdir) |
| `nixmail` | `/mnt/pve/nas/shared/secrets/mail` | `var/lib/secrets/mail` | `rw` | Dovecot/Postfix LDAP configs (rendered from shared token), DKIM keys |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/mail/ldap` | `var/lib/secrets/mail/ldap` | `ro` | Reads nginx ldap.conf generated by nixidm (isolated subdir) |
| `nixvpn` | `/mnt/pve/nas/shared/secrets/wireguard` | `var/lib/secrets/nixvpn` | `rw` | WireGuard server private/public keys |
| `nixidm` | `/mnt/pve/nas/shared/secrets/kanidm` | `var/lib/secrets/kanidm` | `rw` | `idm-admin-password` for the provision hook |
| `nixidm` | `/mnt/pve/nas/shared/secrets/oauth2` | `var/lib/secrets/oauth2` | `rw` | Provisions **all** OAuth2 client secrets (sole writer) |
| `nixforgejo` | `/mnt/pve/nas/shared/secrets/oauth2/forgejo` | `var/lib/secrets/oauth2/forgejo` | `ro` | Forgejo OIDC client secret |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/oauth2/nextcloud` | `var/lib/secrets/oauth2/nextcloud` | `ro` | Nextcloud OIDC client secret |
| `nixmonitoring` | `/mnt/pve/nas/shared/secrets/oauth2/grafana` | `var/lib/secrets/oauth2/grafana` | `ro` | Grafana OIDC client secret |
| `nixmatrix` | `/mnt/pve/nas/shared/secrets/oauth2/matrix` | `var/lib/secrets/oauth2/matrix` | `ro` | Matrix Synapse OIDC client secret |

| `nixvaultwarden` | `/mnt/pve/nas/shared/secrets/oauth2/vaultwarden` | `var/lib/secrets/oauth2/vaultwarden` | `ro` | Vaultwarden OIDC client secret |
| `nixwikijs` | `/mnt/pve/nas/shared/secrets/oauth2/wikijs` | `var/lib/secrets/oauth2/wikijs` | `ro` | Wiki.js OIDC client secret (seeded into the `authentication` table by `wikijs-provision`) |
| `nixpostgres` | `/mnt/pve/nas/shared/secrets/postgres` | `var/lib/secrets/postgres` | `rw` | Provisions **all** DB role passwords (sole writer) |
| `nixforgejo` | `/mnt/pve/nas/shared/secrets/postgres/forgejo` | `var/lib/secrets/postgres/forgejo` | `ro` | Forgejo DB password |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/postgres/roundcube` | `var/lib/secrets/postgres/roundcube` | `ro` | Roundcube DB password |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/postgres/nextcloud` | `var/lib/secrets/postgres/nextcloud` | `ro` | Nextcloud DB password |
| `nixmatrix` | `/mnt/pve/nas/shared/secrets/postgres/matrix` | `var/lib/secrets/postgres/matrix` | `ro` | Matrix DB password |
| `nixvaultwarden` | `/mnt/pve/nas/shared/secrets/postgres/vaultwarden` | `var/lib/secrets/postgres/vaultwarden` | `ro` | Vaultwarden DB password |
| `nixwikijs` | `/mnt/pve/nas/shared/secrets/postgres/wikijs` | `var/lib/secrets/postgres/wikijs` | `ro` | Wiki.js DB password |
| `nixforgejo` | `/mnt/pve/nas/shared/secrets/forgejo` | `var/lib/secrets/forgejo` | `rw` | Forgejo Actions runner registration token |
| `nixopenwebui` | `/mnt/pve/nas/shared/secrets/open-webui` | `var/lib/secrets/open-webui` | `rw` | Open WebUI env (LLM URLs, PKCE client) |
| `nixmatrix` | `/mnt/pve/nas/shared/secrets/matrix` | `var/lib/secrets/matrix` | `rw` | Synapse `secrets.yaml` (DB pw, OIDC config) |
| `nixvaultwarden` | `/mnt/pve/nas/shared/secrets/vaultwarden` | `var/lib/secrets/vaultwarden` | `rw` | Vaultwarden env (DB url, admin token) |
| `nixwikijs` | `/mnt/pve/nas/shared/secrets/wikijs` | `var/lib/secrets/wikijs` | `rw` | Wiki.js admin password (generated locally by `wikijs-provision`) |
| `nixnsd` | `/mnt/pve/nas/shared/secrets/nsd` | `var/lib/secrets/nsd` | `rw` | NSD TSIG sync key |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/nginx` | `var/lib/secrets/nginx` | `ro` | Nextcloud/Roundcube DB pws, Roundcube DES key |
| `nixnginx` | `/mnt/pve/nas/shared/nextcloud-data` | `var/lib/nextcloud-data` | `rw` | Nextcloud user data directory (NFS backed) |

Example `lxc.mount.entry` lines (one per row above):
```ini
# Per-service secrets
lxc.mount.entry: /mnt/pve/nas/shared/secrets/forgejo var/lib/secrets/forgejo none bind,rw 0 0
# Shared SSL certificates
lxc.mount.entry: /mnt/pve/nas/shared/secrets/ssl var/lib/secrets/ssl none bind,ro 0 0
# Shared OAuth2 client secrets — nixidm gets the parent (rw), consumers get their own subdir (ro)
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2 var/lib/secrets/oauth2 none bind,rw 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2/forgejo var/lib/secrets/oauth2/forgejo none bind,ro 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2/vaultwarden var/lib/secrets/oauth2/vaultwarden none bind,ro 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2/wikijs var/lib/secrets/oauth2/wikijs none bind,ro 0 0
# Shared Postgres DB passwords — nixpostgres gets the parent (rw), consumers get their own subdir (ro)
lxc.mount.entry: /mnt/pve/nas/shared/secrets/postgres var/lib/secrets/postgres none bind,rw 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/postgres/forgejo var/lib/secrets/postgres/forgejo none bind,ro 0 0
# Nextcloud user data (NFS backed, read-write)
lxc.mount.entry: /mnt/pve/nas/shared/nextcloud-data var/lib/nextcloud-data none bind,rw 0 0
```

#### Shared SSL Certificates
`nixnsd` runs ACME via DNS-01 challenge and writes the acquired wildcard
certificates to `/var/lib/secrets/ssl/<domain>/` (`fullchain.pem` and
`key.pem`). `nixnginx` and `nixidm` read them read-only from the same NAS
path (see the table above).

#### Shared OAuth2 client secrets
Each non-public OAuth2/OIDC client's basic secret lives in its own directory on
the NAS and is bind-mounted into **both** `nixidm` (read-write, so the Kanidm
provisioning hook is the sole writer) and the consuming container (read-only).
Both sides read the identical file at `/var/lib/secrets/oauth2/<client>/secret`,
so the secret can never drift between Kanidm and the consumer — no manual
copy/sync step is required.

```text
/mnt/pve/nas/shared/secrets/oauth2/
├── forgejo/secret
├── nextcloud/secret
├── grafana/secret
├── matrix/secret
├── vaultwarden/secret
└── wikijs/secret
```

#### Shared Postgres DB passwords
Each service's PostgreSQL role password lives in its own directory on the NAS
and is bind-mounted into **both** `nixpostgres` (read-write, so the
provisioning unit is the sole writer) and the consuming container (read-only).
Both sides read the identical file at
`/var/lib/secrets/postgres/<role>/db-password`, so the password can never drift
between Postgres and the consumer — no manual `ALTER ROLE` or per-container
`setup-*-secrets.sh` step is required.

A `oneshot` unit (`postgresql-password-provisioning`) on `nixpostgres` runs
after `postgresql.service` on every start: for each role it generates a random
password if the file is missing, then **re-applies** the file's contents to the
role via `ALTER ROLE ... WITH PASSWORD`. The file is authoritative — a password
changed via `psql` is reset back to the file on the next restart.

```text
/mnt/pve/nas/shared/secrets/postgres/
├── forgejo/db-password
├── nextcloud/db-password
├── roundcube/db-password
├── matrix/db-password
├── vaultwarden/db-password
└── wikijs/db-password
```

Consumers read the password directly where the NixOS module supports a
`passwordFile`/`dbpassFile` (forgejo, nextcloud, roundcube). For services that
take a bundled env/yaml file (vaultwarden, wiki.js, matrix), a runtime unit /
`preStart` assembles the final file from a per-container template plus the
password read from the shared mount, so the DB password still never lives
outside the shared mount.

#### Shared mail LDAP token
The mail stack (Dovecot, Postfix, nginx-auth-ldap) authenticates to Kanidm's
LDAP interface using a service-account API token (`dn=token` bind).  The token
is a JWS signed by Kanidm's database key material; when the Kanidm DB is
restored or recreated, all previously-issued tokens become invalid
(`KP0022KeyObjectJwsNotAssociated`).

To avoid manual regeneration, `nixidm` auto-generates a fresh `mail_token` on
every Kanidm (re)start via the REST API (`kanidm-mail-token` systemd
service).  Old tokens with the same label are destroyed first to prevent
accumulation.  The token and a pre-rendered `nginx-ldap.conf` are written to
the **isolated `ldap/` subdir** of the shared mail secrets mount, so nixidm
and nixnginx never have access to DKIM keys or Dovecot/Postfix configs that
live alongside under the parent mail directory:

```text
/mnt/pve/nas/shared/secrets/mail/
├── ldap/               # isolated subdir — nixidm (rw) sole writer, nixnginx (ro)
│   ├── ldap-token       # raw JWS token (read by nixmail)
│   └── nginx-ldap.conf  # pre-rendered ldap_server block (read by nixnginx)
├── dovecot/            # rendered by nixmail's mail-ldap-config service (nixmail only)
│   └── ldap-password.txt
├── postfix/            # rendered by nixmail's mail-ldap-config service (nixmail only)
│   ├── ldap-recipients.cf
│   ├── ldap-aliases.cf
│   ├── ldap-senders.cf
│   ├── ldap-catchalls.cf
│   └── ldap-domains.cf
└── dkim/               # DKIM private keys (nixmail only)
```

`nixidm` is the sole writer of `ldap/ldap-token` and `ldap/nginx-ldap.conf`.
`nixmail` mounts the **full** mail directory (rw) — it reads the token from
the `ldap/` subdir and renders the consumer config files into its own
`dovecot/` and `postfix/` subdirs.  `nixnginx` mounts **only** the `ldap/`
subdir (ro) and includes `nginx-ldap.conf` directly.  This isolation ensures
nixidm and nixnginx cannot read DKIM keys or Dovecot/Postfix LDAP configs.

> **One-time NAS setup:** create the `ldap` subdir before the first deploy:
> ```bash
> mkdir -p /mnt/pve/nas/shared/secrets/mail/ldap
> ```


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
* **SSL/TLS Certificates**: Kanidm requires valid SSL certificates to boot. Since these are acquired by `nixnsd` via DNS-01 and placed in the shared SSL storage, mount `/mnt/pve/nas/shared/secrets/ssl` to `/var/lib/secrets/ssl` in the container. Kanidm will read:
  `/var/lib/secrets/ssl/minnecker.com/fullchain.pem` and `/var/lib/secrets/ssl/minnecker.com/key.pem`.
* **Provisioning password & OAuth2 basic secrets**: The declarative provisioning hook in `nixidm/kanidm.nix` authenticates as `idm_admin` and reconciles groups + OAuth2 clients on each start. Place these files under the mounted secrets directories:
  * `/var/lib/secrets/kanidm/idm-admin-password` — the recovered `idm_admin` password (used by the provision hook; `chmod 600`).
  * `/var/lib/secrets/oauth2/<client>/secret` — the basic client secret for each non-public OAuth2 client (`forgejo`, `nextcloud`, `grafana`, `matrix`). The provisioning hook **sets** the client secret to this file's contents on every run, so the file is authoritative. The same file is bind-mounted (read-only) into the consuming container (see the "Shared OAuth2 client secrets" section above), so **no manual copy to the consumer is needed** — both sides read the identical file. Populate it once before the first rebuild (`chmod 600`).

#### 🦊 nixforgejo (Forgejo Git Service)
1. **Database Password**: Read from the shared Postgres secrets mount at `/var/lib/secrets/postgres/forgejo/db-password` (bind-mounted read-only from the NAS; provisioned on `nixpostgres`). No local copy needed.
2. **Kanidm OAuth2/OIDC Secret**: Read from the shared mount at `/var/lib/secrets/oauth2/forgejo/secret` (bind-mounted read-only from the NAS; provisioned on `nixidm`). No local copy needed.
3. **Forgejo Actions Runner Token**: Write `/var/lib/secrets/forgejo/runner-token` (the per-container `rw` mount, `chmod 600`). This is a manual registration token, not a DB password.

#### 📊 nixmonitoring (Grafana, Prometheus & Loki)
* **Grafana Configuration**:
  * `/var/lib/secrets/grafana/admin-password` and `/var/lib/secrets/grafana/secret-key` are generated automatically on first boot by the `grafana-secrets` systemd oneshot (idempotent — existing files are kept). They are local to the container (no NAS mount) since Grafana uses the embedded sqlite DB in its own persistent rootfs; `secret_key` encrypts sensitive values stored there and must not be lost or regenerated after first boot.
  * `/var/lib/secrets/oauth2/grafana/secret` (Kanidm OIDC client secret — shared mount, provisioned on `nixidm`, bind-mounted read-only). This is what wires up SSO; members of `grafana_admins`/`idm_admins` get the Grafana `Admin` role automatically.
  * The oauth2 shared file is owned on the NAS; the two generated files are owned by `grafana:grafana` with `chmod 600` (set by the oneshot).

#### 🤖 nixopenwebui (Open WebUI)
* **SSO & LLM Configuration**: Fully declarative — no manual secret step. Open WebUI is a public PKCE OAuth2 client against Kanidm (provisioned on `nixidm`, no shared basic secret — only the client id `open-webui` is needed, set in the module). The LLM endpoint (`OPENAI_API_BASE_URL` / `OPENAI_API_KEY`, Ollama API disabled) is declared in `nixopenwebui/open-webui.nix`. The `open-webui-secrets` systemd oneshot provisions an empty, idempotent `/var/lib/secrets/open-webui/env` (owned by `root:root`, `chmod 600` — the service uses `DynamicUser` so systemd's manager, running as root, reads the `EnvironmentFile` before spawning the dynamic UID) on every service start so the `EnvironmentFile` directive always has a target. To override the LLM endpoint at runtime (e.g. point at a different model server), drop lines into that file; otherwise leave it empty.

#### 💬 nixmatrix (Matrix Synapse)
* **Synapse Configuration**: `/var/lib/secrets/matrix/secrets.yaml` (owned by `matrix-synapse:matrix-synapse`, `chmod 600`) is **provisioned automatically on first boot** by the `matrix-synapse-secrets` systemd oneshot (idempotent — existing files are kept). It contains the **OIDC client config** with placeholder values only; the database password and OIDC client secret are both rewritten on every Synapse start from their shared mounts, so no manual secret material is needed here. The generated template is:
  ```yaml
  database:
    args:
      password: "PLACEHOLDER_REWRITTEN_FROM_SHARED_MOUNT"
  oidc_providers:
    - idp_id: "kanidm"
      idp_name: "Kanidm SSO"
      issuer: "https://idm.minnecker.com/oauth2/openid/matrix"
      client_id: "matrix"
      client_secret: "PLACEHOLDER_REWRITTEN_FROM_SHARED_MOUNT"
      scopes: ["openid", "profile", "email"]
      user_mapping_provider:
        config:
          subject_claim: "sub"
          localpart_claim: "preferred_username"
          display_name_claim: "name"
          email_claim: "email"
  ```
  * The `password` line is **rewritten on every Synapse start** from the shared Postgres secrets mount at `/var/lib/secrets/postgres/matrix/db-password` (provisioned on `nixpostgres`), so the value above is only the initial placeholder — it stays in sync with the role's actual password automatically.
  * The `client_secret` line is **rewritten on every Synapse start** from the shared OAuth2 secret mount at `/var/lib/secrets/oauth2/matrix/secret` (provisioned on `nixidm`), so the value above is only the initial placeholder — it stays in sync with Kanidm automatically.

#### 🔑 nixvaultwarden (Vaultwarden)
* **Admin Token**: Auto-provisioned on first boot by the `vaultwarden-admin-token` service into `/var/lib/secrets/vaultwarden/env-template` (a random `ADMIN_TOKEN` generated with `openssl rand -base64 48`). The file is created with `0600` / `vaultwarden:vaultwarden` ownership and left untouched on subsequent starts. To retrieve the generated value (or rotate it), inspect/replace the file directly.
  The database password is **not** in this file. On every start, the `vaultwarden-secrets` unit assembles `/run/vaultwarden/env` from this template plus the DB password read from the shared Postgres secrets mount at `/var/lib/secrets/postgres/vaultwarden/db-password` (provisioned on `nixpostgres`, read-only here), producing the final `DATABASE_URL=postgresql://vaultwarden:<password>@nixpostgres/vaultwarden`. The same unit also injects `SSO_CLIENT_SECRET` from the shared OAuth2 secrets mount at `/var/lib/secrets/oauth2/vaultwarden/secret` (provisioned on `nixidm`, read-only here) — no manual copy to the consumer is needed.

#### 📝 nixwikijs (Wiki.js)
* **Database Password**: No local secret file is needed. On every start, the `wikijs-secrets` unit assembles `/run/wikijs/env` from the DB password read from the shared Postgres secrets mount at `/var/lib/secrets/postgres/wikijs/db-password` (provisioned on `nixpostgres`, read-only here), producing `WIKI_DB_PASS=<password>`.
* **Admin Password**: Auto-provisioned on first boot into `/var/lib/secrets/wikijs/admin-password` (a random value generated with `openssl rand -base64 32`, owned root `0600`). Used only by the `wikijs-provision` unit to drive the one-time setup wizard; retrieve it to log in as the local `admin@minnecker.com` account (OIDC users are the primary logins).
* **OIDC (Kanidm)**: Fully declarative — no manual setup-wizard or admin-UI step. On every start, the `wikijs-provision` oneshot: (1) upserts the Kanidm OIDC strategy row into Wiki.js' `authentication` table, reading the client secret from the shared OAuth2 secrets mount at `/var/lib/secrets/oauth2/wikijs/secret` (provisioned on `nixidm`, read-only here); (2) on first boot, drives the setup wizard via `POST /finalize` (admin email/password + `siteUrl=https://wiki.minnecker.com`), after which Wiki.js self-boots into master mode and activates the pre-seeded OIDC strategy; (3) on later boots, restarts Wiki.js only if the Kanidm client secret has rotated. Note: Wiki.js has no OIDC→admin role mapping, so promoting an OIDC user to the `Administrators` group is a one-time manual click in the admin UI (like forgejo/matrix).

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

---

## 🌐 4. Exposing Services & Host Port Routing (NAT)

To allow external access to your containers on Proxmox, you must forward the public ports of the Proxmox host to the respective container IPs.

### 🛠️ Port Routing Script
A host routing script has been created under [scratch/setup-host-routing.sh](file:///root/nixos-config/scratch/setup-host-routing.sh). Copy this script to your Proxmox host (e.g. `/root/setup-host-routing.sh`) and configure the `PUB_IF` variable matching your public network interface (e.g. `vmbr0`).

#### Run Routing Temporarily (Runtime only)
To enable rules on-the-fly:
```bash
# Enable forwarding and apply NAT rules
sudo /root/setup-host-routing.sh enable

# Disable all forwarded NAT rules
sudo /root/setup-host-routing.sh disable

# View active forwardings
sudo /root/setup-host-routing.sh status
```

#### Run Routing Permanently
To make the port routing rules persistent across host reboots:

**Option A: Add to network interfaces configuration (Recommended)**
Edit `/etc/network/interfaces` on your Proxmox host and append the enable/disable triggers under your main bridge configuration (e.g. `vmbr0`):
```text
iface vmbr0 inet static
    # ... your existing configuration ...
    post-up /root/setup-host-routing.sh enable
    post-down /root/setup-host-routing.sh disable
```

**Option B: Use `iptables-persistent`**
Install the persistence package and save active iptables NAT rules:
```bash
sudo apt-get install -y iptables-persistent
sudo iptables-save > /etc/iptables/rules.v4
```
