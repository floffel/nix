# NixOS Kanidm Configuration (`nixidm`)

This directory contains the NixOS configuration files for the Kanidm identity management server container (`nixidm`). Kanidm serves as the centralized identity provider (IdP) for all services, exposing a read-only LDAP gateway (port 636) and OAuth2/OIDC authentication endpoints (port 8443).

---

## 🚀 1. Post-Installation Database Initialization

If you are setting up `nixidm` from scratch or after re-initializing the database:

### 1. Initialize the Database
Boot the Kanidm container and run the standard initialization command to generate the administrator credentials:
```bash
kanidmd recover-init admin
```
*(This command will output the generated passwords for `admin` and `idm_admin`—save these securely!)*

### 2. Provide the idm_admin provisioning password
The NixOS module reconciles the directory against the declarative state in
[`kanidm.nix`](kanidm.nix) on every Kanidm start (via an `ExecStartPost` hook).
To do so it authenticates as `idm_admin` using a stable password instead of
regenerating one each restart. Write the recovered `idm_admin` password to the
shared secrets mount so the provisioning hook can read it:

```bash
mkdir -p /var/lib/secrets/kanidm && chmod 700 /var/lib/secrets/kanidm
# Set the password recovered in step 1 (or reset it with: kanidmd recover-account idm_admin)
printf '%s' 'YOUR_IDM_ADMIN_PASSWORD' > /var/lib/secrets/kanidm/idm-admin-password
chmod 600 /var/lib/secrets/kanidm/idm-admin-password
```

### 3. Login to the CLI
On the container CLI, log in as `admin` to verify credentials:
```bash
kanidm login -D admin
```

---

## 🧩 2. Declarative Provisioning (Groups & OAuth2 Clients)

The access-control groups and OAuth2/OIDC resource servers consumed by every
downstream service are declared in [`kanidm.nix`](kanidm.nix) under
`services.kanidm.provision` and are reconciled automatically on each Kanidm
start. **You no longer need to run the per-service `kanidm system oauth2
create ...` / `group create ...` commands by hand.**

### Provisioned groups
Access-control groups (membership managed via CLI/Web UI, see §3):
`mail_users`, `forgejo_users`, `nextcloud_users`, `grafana_users`,
`matrix_users`, `open_webui_users`.

Per-service admin groups (only for services that support OIDC-driven admin):
`nextcloud_admins`, `grafana_admins`, `open_webui_admins`. Plus the built-in
`idm_admins` group, declared so the claimMaps below can reference it; members
of `idm_admins` are granted admin in every service that supports OIDC-driven
admin as a global fallback. Forgejo and Matrix have no OIDC admin mapping, so
no admin group is declared for them — promote admins manually in those apps.

### Provisioned OAuth2/OIDC clients & admin mapping
| Client | Access group | Admin group(s) → admin claim | Redirect URL | Secret |
| :--- | :--- | :--- | :--- | :--- |
| `forgejo` | `forgejo_users` | *(none — promote manually)* | `https://git.minnecker.com/user/oauth2/kanidm/callback` | basic secret file |
| `nextcloud` | `nextcloud_users` | `nextcloud_admins` + `idm_admins` → `groups` claim value `admin` | `https://cloud.minnecker.com/index.php/apps/user_oidc/code` | basic secret file |
| `grafana` | `grafana_users` | `grafana_admins` + `idm_admins` → `groups` claim value `admin` | `https://monitoring.minnecker.com/generic_oauth/callback` | basic secret file |
| `matrix` | `matrix_users` | *(none — promote manually)* | `https://matrix.minnecker.com/_synapse/client/oauth2/callback` | basic secret file |
| `open-webui` | `open_webui_users` | `open_webui_admins` + `idm_admins` → `roles` claim value `admin` | `https://ai.minnecker.com/oauth/oidc/callback` | public (PKCE, no secret) |

> [!NOTE]
> Forgejo and Matrix Synapse have **no upstream OIDC admin mapping** — admins
> must be promoted manually in the app (Forgejo admin panel; Synapse Admin
> API). Nextcloud (`user_oidc` `groups` claim), Grafana (`groups` claim with
> `admin` value) and Open WebUI (`roles` claim with `admin` value) are granted
> admin automatically when a user is in the corresponding admin group (or
> `idm_admins`).

### One-time secrets for non-public clients
Each non-public OAuth2 client (`forgejo`, `nextcloud`, `grafana`, `matrix`)
reads a basic client secret from a **per-client directory on the shared OAuth2
secrets mount** (`/var/lib/secrets/oauth2/<client>/secret`). The provisioning
hook **sets** the client's secret to the contents of that file on every run, so
the file must exist and be populated with your chosen secret before the first
`nixos-rebuild switch`.

The same file is bind-mounted **read-only** into the consuming container at the
identical path, so both Kanidm and the consumer always read the same secret —
**no manual copy/sync to the consumer is needed.** See the root README's
"Shared OAuth2 client secrets" section for the Proxmox mount entries.

```bash
# On nixidm, pre-populate the basic secrets (one per non-public client).
# The /var/lib/secrets/oauth2 mount is read-write here.
mkdir -p /var/lib/secrets/oauth2/{forgejo,nextcloud,grafana,matrix}
for c in forgejo nextcloud grafana matrix; do
  printf '%s' "$(openssl rand -hex 32)" > /var/lib/secrets/oauth2/$c/secret
  chmod 600 /var/lib/secrets/oauth2/$c/secret
done
```

> [!IMPORTANT]
> Because the provisioning hook re-applies the secret from the file on every
> Kanidm restart, the value in the file **is** the authoritative client secret.
> Do not run `kanidm system oauth2 show-basic-secret` expecting it to differ —
> it will match the file contents.
>
> `open-webui` is a public PKCE client and has no basic secret; the consumer
> only needs its client id (`open-webui`).

> [!NOTE]
> Person accounts are intentionally **not** declared in Nix. Create and manage
> users via the Kanidm CLI or Web UI as described in §3. Adding a person to a
> provisioned group is what grants them access to the corresponding service.

---

## 👥 3. User & Group Administration

Use these commands to manage users, groups, and passwords.

### Convenience CLI helper
The [`scratch/idm-users.sh`](../scratch/idm-users.sh) script wraps the `kanidm`
CLI into a simple CRUD interface for onboarding and day-to-day admin. Run it on
the `nixidm` container — it auto-logs in as `idm_admin` using the password in
`/var/lib/secrets/kanidm/idm-admin-password` (the same file the provisioning
hook uses), so a manual `kanidm login -D idm_admin` is no longer required:

```bash
# Interactive guided creation — prompts for username, display name, one or
# more mail addresses (first = primary), an optional catch-all domain (the
# user becomes the mail_users recipient for unmatched mail on that domain),
# and a multi-select of service groups. Issues a reset token at the end.
./scratch/idm-users.sh user new

# Create a user non-interactively (no password is set at creation time — see §3 below)
./scratch/idm-users.sh user create alice "Alice Example" alice@minnecker.com admin@minnecker.com

# Inspect / list / delete
./scratch/idm-users.sh user get alice
./scratch/idm-users.sh user list
./scratch/idm-users.sh user delete alice

# Issue a single-use reset token so Alice sets her own password (+ optional passkey/MFA)
./scratch/idm-users.sh user reset-token alice            # default 1h TTL
./scratch/idm-users.sh user reset-token alice 86400      # 24h (max)

# Lock (expire) an account instantly
./scratch/idm-users.sh user lock alice

# Unlock (clear expiry) an account
./scratch/idm-users.sh user unlock alice

# Edit a user (display/legal name, mail list, rename)
./scratch/idm-users.sh user set-name alice "Alice Example" --legal "Alice Q. Example"
./scratch/idm-users.sh user set-mail alice alice@minnecker.com alice.personal@minnecker.com
./scratch/idm-users.sh user add-mail alice alice.alias@minnecker.com
./scratch/idm-users.sh user del-mail alice alice.personal@minnecker.com
./scratch/idm-users.sh user rename alice alice.smith

# Group membership (groups themselves are provisioned declaratively in kanidm.nix;
# use create/delete only for ad-hoc groups)
./scratch/idm-users.sh group list
./scratch/idm-users.sh group members mail_users
./scratch/idm-users.sh group add mail_users alice bob
./scratch/idm-users.sh group remove mail_users bob
./scratch/idm-users.sh group create adhoc-project
./scratch/idm-users.sh group delete adhoc-project

# Service access (friendly layer over the provisioned authorization groups)
# `access list` shows every service group and its members — the quickest way
# to answer "who can log into what" (login is gated on scopeMaps in kanidm.nix).
# Short aliases are accepted: mail, forgejo, nextcloud, nextcloud-admin,
# grafana, grafana-admin, matrix, openwebui/open-webui, openwebui-admin, idm-admins.
./scratch/idm-users.sh access                       # list all service groups + members
./scratch/idm-users.sh access grafana                # show members of one service group
./scratch/idm-users.sh access add grafana alice      # grant Grafana access to alice
./scratch/idm-users.sh access remove mail bob        # revoke Mail access from bob

# Account policy / MFA (credential floor resolves to the strictest among a user's groups)
./scratch/idm-users.sh policy get idm_all_persons
./scratch/idm-users.sh policy enable mail_users
./scratch/idm-users.sh policy min-credential idm_all_persons any     # allow plain password globally
./scratch/idm-users.sh policy min-credential mail_users mfa          # require MFA for this group

# Service-account API token (e.g. the `mailservice` LDAP bind token for nixmail/nixnginx)
./scratch/idm-users.sh svc-token create mailservice "Mail Search Service" mail_token
./scratch/idm-users.sh svc-token status mailservice
./scratch/idm-users.sh svc-token revoke mailservice <token_id>

# OAuth2/OIDC clients (declared provisioned in kanidm.nix; read-only here)
./scratch/idm-users.sh oauth2 list
./scratch/idm-users.sh oauth2 get forgejo
# Print a non-public client's basic secret straight from the shared secrets
# file (the same file bind-mounted into the consuming container). Useful for
# inspecting the value or seeding a fresh NAS share — no manual copy to the
# consumer is needed since both sides read the identical file:
./scratch/idm-users.sh oauth2 secret forgejo
```

Override the acting admin with `KANIDM_ADMIN=...`, the auto-login password file
with `KANIDM_ADMIN_PASSFILE=...`, the OAuth2 secrets dir with
`KANIDM_OAUTH2_SECRETS=...`, or the default reset-token TTL with `RESET_TTL=...`
(env vars). Set `KANIDM_SKIP_LOGIN=1` to skip the auto-login attempt.

### Creating a user (manual equivalent of the script)
```bash
kanidm -D idm_admin person create username "Display Name"
kanidm -D idm_admin person update username --mail username@minnecker.com
```
*(The first `--mail` is the primary address; additional `--mail` flags are aliases.)*

### Passwords — reset-token flow (no shared temp password)
Kanidm has **no** `--password` flag for `person create`. Instead of setting a
temporary password an administrator can read, issue a **single-use credential
reset token** that the user redeems in the web UI to set their own password and
optionally enroll a passkey/MFA. The token is invalidated as soon as it is used
and expires after its TTL (default 1h, max 24h).

```bash
# Prints a QR code plus a redeem URL like:
#   https://idm.minnecker.com/ui/reset?token=XXXX-XXXX-XXXX-XXXX
kanidm -D idm_admin person credential create-reset-token username --ttl=3600        # 1h
kanidm -D idm_admin person credential create-reset-token username --ttl=86400  # 24h
```
Send the printed link to the user. They visit it once to set their credential.
This is the intended non-interactive/admin-driven onboarding path; the script's
`user reset-token` command wraps this.

### Self-Service Password Changes (For Standard Users)
* **Via WebUI (Recommended):** Log in to the Kanidm Web UI dashboard (e.g. `https://idm.minnecker.com`) and navigate to **Profile** settings to change passwords or configure passkeys/MFA.
* **Via CLI:**
  ```bash
  kanidm login -D username
  kanidm person credential update username
  ```

### Disabling the mandatory second factor (MFA)
By default Kanidm does **not** require a second factor for everyone; the
credential floor is controlled per-group via Account Policy, and the policy that
applies to all persons lives on the built-in `idm_all_persons` group. To allow a
plain password (no MFA/passkey required) for everyone, set the floor to `any`:

```bash
kanidm -D idm_admin group account-policy credential-type-minimum idm_all_persons any
```
The credential-type floor resolves to the **strictest** among a user's groups
(ordered `any < mfa < passkey < attested_passkey`), so if you later scope a
group to `mfa`/`passkey` its members will need that factor regardless of the
global floor. To require MFA for a specific group instead of globally:

```bash
kanidm -D idm_admin group account-policy enable <group>
kanidm -D idm_admin group account-policy credential-type-minimum <group> mfa
```

### Deleting a User
```bash
kanidm -D idm_admin person delete username
```

### Creating a Group
Groups used by services are **declared provisioned** in `kanidm.nix` and created
automatically. For ad-hoc groups only:
```bash
kanidm -D idm_admin group create group_name idm_admins
```

### Managing Group Membership
```bash
# Add user(s) to a group
kanidm -D idm_admin group add-members group_name username

# Remove user(s) from a group
kanidm -D idm_admin group remove-members group_name username

# List members of a group
kanidm -D idm_admin group list-members group_name
```

---

## 🔒 3. Service Authorization (Enforcing Access Control)

By default, any user in the directory could log into services once integrated. To restrict access (e.g., creating a user who has access to Matrix and Mail, but *not* Nextcloud), you can enforce authorization at the identity provider level.

### A. Mail Server Authorization (LDAP)
The mail server (`nixmail`) checks group membership via LDAP before accepting mail or authenticating users.
* **How it works:** Postfix and Dovecot queries are configured to check `(memberof=cn=mail_users,ou=groups,dc=yourdomain,dc=com)`.
* **To authorize a user:** Simply add them to the `mail_users` group:
  ```bash
  kanidm -D idm_admin group add-members mail_users username
  ```
* **To revoke access:** Remove them from the group:
  ```bash
  kanidm -D idm_admin group remove-members mail_users username
  ```

### B. OAuth2/OIDC Service Authorization (Nextcloud, Matrix, Forgejo, etc.)
The OAuth2 clients, their authorization groups, and scope maps are **declared
provisioned** in [`kanidm.nix`](kanidm.nix) (see §2). A user can only receive
the scopes (`openid`, `profile`, `email`, ...) an OAuth2 client requests if they
are a member of the group mapped to those scopes; otherwise the OIDC login flow
fails. So to grant or revoke service access you only manage group membership —
no `system oauth2` CLI commands are needed:

```bash
# Grant access to a service (group already exists via provisioning)
kanidm -D idm_admin group add-members nextcloud_users username
# or via the helper:
./scratch/idm-users.sh group add nextcloud_users username

# Revoke access
kanidm -D idm_admin group remove-members nextcloud_users username
```

To add an entirely new service client/group, edit `kanidm.nix` and rebuild; the
provisioning hook reconciles the directory on the next Kanidm start.

---

## 📋 Example: Configuring a Restricted User

Suppose you want to create a contractor account named `alice`:
* Authorized to use: **Matrix** and **Mail**
* Blocked from using: **Nextcloud**

Using the helper script:

```bash
# 1. Create the account + email (no password set at creation)
./scratch/idm-users.sh user create alice "Alice Contractor" alice@example.com

# 2. Issue a one-time reset token so Alice sets her own password
./scratch/idm-users.sh user reset-token alice

# 3. Authorize Mail & Matrix (groups are provisioned in kanidm.nix)
./scratch/idm-users.sh group add mail_users alice
./scratch/idm-users.sh group add matrix_users alice
```

Since Alice is **not** added to `nextcloud_users`, any SSO login attempt to
Nextcloud is blocked by Kanidm.
