# Forgejo Git Server Configuration (`nixforgejo`)

This directory contains the NixOS configuration files for the Forgejo Git hosting server container (`nixforgejo`).

---

## 🛠️ Deployment Step-by-Step

Setting up the Forgejo container involves initializing the Postgres database role, registering the OIDC client in Kanidm, writing secure runtime secrets, and switching the NixOS configuration.

---

### Step 1: Initialize Database Role (on `nixpostgres`)

1. Log into the `nixpostgres` container as root.
2. Run the secure random password generator script to set the passwords for all service roles:
   ```bash
   /root/nixos-config/scratch/setup-postgres-passwords.sh
   ```
3. Copy the outputted password for the **`forgejo`** role.

---

### Step 2: OIDC Client (provisioned on `nixidm`)

The Forgejo OAuth2/OIDC client (`forgejo`) and its `forgejo_users`
authorization group are **declared provisioned** in
[`nixidm/kanidm.nix`](../nixidm/kanidm.nix) and reconciled automatically on
each Kanidm start — you no longer create them by hand.

The client's basic secret lives in the **shared OAuth2 secrets mount** at
`/var/lib/secrets/oauth2/forgejo/secret`. This file is bind-mounted into
**both** `nixidm` (read-write, so the provisioning hook writes it) and
`nixforgejo` (read-only). Forgejo reads the same file, so no manual copy/sync
is needed — the two can never drift. Populate it once on `nixidm` (see the
`nixidm` README's "One-time secrets for non-public clients" section) and add
the Proxmox bind-mount entries (see the root README's "Shared OAuth2 client
secrets" section).

To grant a user access to Forgejo afterwards, add them to the provisioned
group:
```bash
kanidm -D idm_admin group add-members forgejo_users <username>
```

> [!NOTE]
> Forgejo has no upstream OIDC admin mapping, so OIDC cannot grant the admin
> role automatically. To make a user a Forgejo administrator, promote them
> manually in the Forgejo admin panel (Site Administration → Users → Edit).

---

### Step 3: Configure Secrets and Switch (on `nixforgejo`)

Log into the `nixforgejo` container as root:

1. **Pull the latest configuration updates**:
   ```bash
   cd /root/nixos-config && git pull
   ```
2. **Execute the Secrets Setup Helper Script**:
   Provide the Postgres database password (from Step 1). The OAuth OIDC client
   secret no longer needs to be written here — it comes from the shared mount
   provisioned on `nixidm` (Step 2):
   ```bash
   ./scratch/setup-forgejo-secrets.sh <FORGEJO_DB_PASSWORD>
   ```
   *(This script creates `/var/lib/secrets/forgejo` and writes `db-password`
   with secure `0600` permissions. The OAuth secret is read from the
   read-only shared mount at `/var/lib/secrets/oauth2/forgejo/secret`.)*
3. **Switch to the New Configuration**:
   ```bash
   nixos-rebuild switch
   ```

---

## 🔒 Post-Start Automation

When `nixforgejo` boots, a systemd postStart task automatically runs `forgejo admin auth` CLI commands to check if the `"kanidm"` authentication source exists. If not, it registers it with the OIDC endpoint.

Standard users will immediately see a **Kanidm SSO** button on the Forgejo login page!

### Troubleshooting: `OAuth2 RetrieveError: ... 401 Unauthorized`

This error at the OIDC token-exchange step means the client secret Forgejo has
stored no longer matches the secret Kanidm expects for the `forgejo` OAuth2
client. With the shared OAuth2 secrets mount, Forgejo and Kanidm read the
**same file** (`/var/lib/secrets/oauth2/forgejo/secret`), so this drift can no
longer happen under normal operation.

The `postStart` hook rewrites Forgejo's stored secret from that shared file on
every boot. If you still see a 401, the usual cause is a stale stored secret
from before the shared mount was in use, or the mount not being attached. To
recover:

1. Ensure the shared mount is present and readable:
   ```bash
   ls -l /var/lib/secrets/oauth2/forgejo/secret
   ```
2. Restart Forgejo so `postStart` re-syncs the secret from the shared file:
   ```bash
   systemctl restart forgejo
   ```

Note: being a member of `forgejo_users` only authorizes the OIDC scope grant —
the 401 happens *before* that, during client (secret) authentication, so group
membership is never the cause of this specific error.
