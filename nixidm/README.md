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

### 2. Login to the CLI
On the container CLI, log in as `admin` to verify credentials:
```bash
kanidm login -D admin
```

---

## 👥 2. User & Group Administration

Use these commands to manage users, groups, and passwords.

### Creating a User
```bash
kanidm -D idm_admin person create username "Display Name"
```

### Setting/Updating a User's Password (As Administrator)
```bash
kanidm -D idm_admin person credential update username
```
*(This command will prompt you interactively to input the new password.)*

### Self-Service Password Changes (For Standard Users)
Standard users can update their own passwords:
* **Via WebUI (Recommended):** Log in to the Kanidm Web UI dashboard (e.g. `https://idm.minnecker.com`) and navigate to **Profile** settings to change passwords or configure passkeys/MFA.
* **Via CLI:**
  ```bash
  kanidm login -D username
  kanidm person credential update username
  ```

### Deleting a User
```bash
kanidm -D idm_admin person delete username
```

### Creating a Group
```bash
kanidm -D idm_admin group create group_name idm_admins
kanidm -D idm_admin group set-description group_name "Group Description"
```

### Managing Group Membership
```bash
# Add user to a group
kanidm -D idm_admin group add-members group_name username

# Remove user from a group
kanidm -D idm_admin group remove-members group_name username
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
Kanidm allows you to restrict OAuth2/OIDC clients by mapping scopes to specific groups. If a user is not in a mapped group, they cannot receive the scopes (like `openid`, `profile`, `email`) requested by the application, and the OIDC login flow will fail.

#### Step 1: Create a group for the service
```bash
kanidm -D idm_admin group create nextcloud_users idm_admins
kanidm -D idm_admin group set-description nextcloud_users "Users authorized to access Nextcloud"
```

#### Step 2: Map the scopes to the group
Restrict the OAuth2 client (e.g., `nextcloud`) to only authorize members of `nextcloud_users`:
```bash
kanidm -D idm_admin system oauth2 update-scope-map nextcloud nextcloud_users openid profile email
```

#### Step 3: Grant access to a user
```bash
kanidm -D idm_admin group add-members nextcloud_users username
```
*(Now, only users added to `nextcloud_users` can log in to Nextcloud. Unmapped users will be denied access during authentication.)*

---

## 📋 Example: Configuring a Restricted User

Suppose you want to create a contractor account named `alice`:
* Authorized to use: **Matrix** and **Mail**
* Blocked from using: **Nextcloud**

### 1. Create the account
```bash
kanidm -D idm_admin person create alice "Alice Contractor"
kanidm -D idm_admin person credential update alice
```

### 2. Set email & alias
```bash
kanidm -D idm_admin person update alice --mail alice@example.com
```

### 3. Authorize Mail & Matrix
```bash
# Add to Mail access group
kanidm -D idm_admin group add-members mail_users alice

# Add to Matrix access group (assuming 'matrix' scope-map is restricted to 'matrix_users')
kanidm -D idm_admin group add-members matrix_users alice
```
*(Since Alice is not added to the `nextcloud_users` group, any attempts she makes to log into Nextcloud via SSO will be blocked by Kanidm.)*
