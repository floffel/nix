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

### Step 2: Register OIDC Client (on `nixidm`)

Log into the `nixidm` container as root and run the following commands:

1. **Create the OAuth2/OIDC Client** in Kanidm:
   ```bash
   kanidm -D idm_admin system oauth2 create forgejo "Forgejo Git" https://git.minnecker.com
   ```
2. **Register the OAuth2 Redirect URL**:
   ```bash
   kanidm -D idm_admin system oauth2 add-redirect-url forgejo https://git.minnecker.com/user/oauth2/kanidm/callback
   ```
3. **Retrieve the OIDC Client Secret**:
   ```bash
   kanidm -D idm_admin system oauth2 show-basic-secret forgejo
   ```
   *(Note down the returned basic client secret).*
4. **Create the Authorization Group**:
   ```bash
   kanidm -D idm_admin group create forgejo_users idm_admins
   kanidm -D idm_admin group set-description forgejo_users "Users authorized to access Forgejo"
   ```
5. **Map requested scopes** to only authorize members of the `forgejo_users` group:
   ```bash
   kanidm -D idm_admin system oauth2 update-scope-map forgejo forgejo_users openid profile email
   ```
6. **Grant access to users**:
   ```bash
   kanidm -D idm_admin group add-members forgejo_users <username>
   ```

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
