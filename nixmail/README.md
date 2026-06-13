# NixOS Mail Server Configuration (`nixmail`)

This directory contains the NixOS configuration files for the mail server container (`nixmail`), which runs Postfix and Dovecot integrated with a local Kanidm identity provider for dynamic authentication and mail routing.

## 📐 Architecture & Lookup Logic

All user configuration, aliases, catch-alls, and valid domains are configured dynamically in the identity provider (Kanidm) via LDAP queries, keeping the mail server state-free.

1. **Virtual Mailbox Domains:** Valid email domains are looked up dynamically using the LDAP filter `(mail=*@%s)`. If any account in Kanidm has an email address ending in `@domain.com`, Postfix automatically accepts `domain.com` as a valid virtual mailbox domain.
2. **Mailboxes & Aliases:** Valid recipient addresses are matched against the `mail` attribute of users who are members of the `mail_users` group.
3. **Catch-All Routing (Wildcards):** Postfix first queries for the specific email address (e.g. `user@domain.com`). If it doesn't exist, it queries the catch-all LDAP map for `mail=*@domain.com`. Setting `*@domain.com` as an alias on a user in Kanidm will route all unmatched mail for that domain to them.

---

## 🛠️ Step-by-Step Directory Setup (Examples)

Here is how to set up mailboxes, aliases, and catch-alls in Kanidm using example domains (`example.com`, `example.org`) and usernames (`john`, `jane`).

### 1. Create the Mail Group
Create a group that authorizes members to access the mail service:
```bash
# Create the group managed by idm_admins
kanidm -D idm_admin group create mail_users idm_admins

# Set a descriptive display name
kanidm -D idm_admin group set-description mail_users "Mail Server Users"
```

### 2. Create User Accounts & Set Passwords
```bash
# Create the users
kanidm -D idm_admin person create john "John Doe"
kanidm -D idm_admin person create jane "Jane Smith"

# Set their passwords (you will be prompted interactively)
kanidm -D idm_admin person credential update john
kanidm -D idm_admin person credential update jane
```

### 3. Configure Email Addresses & Catch-Alls
Update the user's `mail` attribute. The first email address specified is the primary mailbox. Additional entries act as aliases or catch-alls. 

> [!IMPORTANT]
> When setting catch-alls, you must use the `*` prefix (e.g. `"*@domain.com"`). Always wrap these values in **double quotes** to prevent your shell from interpreting the asterisk `*` character.

```bash
# Configure John (Primary mailbox, admin alias, and catch-alls for two domains)
kanidm -D idm_admin person update john \
  --mail john@example.com \
  --mail admin@example.com \
  --mail "*@example.com" \
  --mail "*@example.org"

# Configure Jane (Primary mailbox and standard alias)
kanidm -D idm_admin person update jane \
  --mail jane@example.com \
  --mail j.smith@example.com
```

### 4. Grant Mail Access
Add the configured users to the `mail_users` group:
```bash
kanidm -D idm_admin group add-members mail_users john jane
```

---

## 🚀 Mail Server Secrets Setup

To generate the secure LDAP query files and authenticate Dovecot/Postfix:

1. **Generate service account API token:**
   In your Kanidm shell, generate a token for the mail service account:
   ```bash
   kanidm -D idm_admin service-account api-token generate mailservice mail_token
   ```

2. **Initialize configuration files on `nixmail`:**
   Log into the `nixmail` server, pull the latest git changes, and run the helper script with the generated API token:
   ```bash
   # Run the script (this generates LDAP maps inside /var/lib/secrets/mail/)
   ./scratch/setup-mail-secrets.sh "<API_TOKEN>"
   ```

3. **Rebuild the NixOS configuration:**
   ```bash
   nixos-rebuild switch
   ```
