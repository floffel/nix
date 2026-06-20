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

The client's basic secret is the contents of
`/var/lib/secrets/kanidm/oauth2-forgejo-basic-secret` on the `nixidm`
container (see the `nixidm` README for how to populate it). Copy that same
value to `nixforgejo` as the `oauth-secret` used in Step 3. From `nixidm` you
can push it directly with the helper (no manual `show-basic-secret`/`cat`):
```bash
./scratch/idm-users.sh oauth2 secret forgejo \
  | ssh nixforgejo 'cat > /var/lib/secrets/forgejo/oauth-secret'
```

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
   Provide the Postgres database password (from Step 1) and the OAuth OIDC client secret (from Step 2):
   ```bash
   ./scratch/setup-forgejo-secrets.sh <FORGEJO_DB_PASSWORD> <FORGEJO_OAUTH_SECRET>
   ```
   *(This script automatically creates `/var/lib/secrets/forgejo` and configures the files with secure `0600` permissions).*
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
client. The most common cause is that
`/var/lib/secrets/kanidm/oauth2-forgejo-basic-secret` on `nixidm` was
regenerated after the auth source was first created (the Kanidm provisioning
hook re-applies that file's value on every Kanidm restart).

The `postStart` hook reconciles this on every boot: it rewrites the stored
secret via `forgejo admin auth update-oauth` to match
`/var/lib/secrets/forgejo/oauth-secret`. So to recover from a 401:

1. Ensure `/var/lib/secrets/forgejo/oauth-secret` on `nixforgejo` contains the
   **same** value as `/var/lib/secrets/kanidm/oauth2-forgejo-basic-secret` on
   `nixidm` (see the `nixidm` README).
2. Restart Forgejo (or its `postStart`) so the secret is re-synced:
   ```bash
   systemctl restart forgejo
   ```

Note: being a member of `forgejo_users` only authorizes the OIDC scope grant —
the 401 happens *before* that, during client (secret) authentication, so group
membership is never the cause of this specific error.
