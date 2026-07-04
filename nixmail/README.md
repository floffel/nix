# NixOS Mail Server Configuration (`nixmail`)

This directory contains the NixOS configuration files for the mail server container (`nixmail`), which runs Postfix and Dovecot integrated with a local Kanidm identity provider for dynamic authentication and mail routing.

## 📐 Architecture & Lookup Logic

All user configuration, aliases, catch-alls, and valid domains are configured dynamically in the identity provider (Kanidm) via LDAP queries, keeping the mail server state-free.

1. **Virtual Mailbox Domains:** Valid email domains are looked up dynamically using the LDAP filter `(mail=*@%s)`. If any account in Kanidm has an email address ending in `@domain.com`, Postfix automatically accepts `domain.com` as a valid virtual mailbox domain.
2. **Mailboxes & Aliases:** Valid recipient addresses are matched against the `mail` attribute of users who are members of the `mail_users` group.
3. **Catch-All Routing (Wildcards):** Postfix first queries for the specific email address (e.g. `user@domain.com`). If it doesn't exist, it queries the catch-all LDAP map for `mail=*@domain.com`. Setting `*@domain.com` as an alias on a user in Kanidm will route all unmatched mail for that domain to them.

---

## 🔐 Authentication

Mail clients authenticate via one of two mechanisms:

### OAuth2 (XOAUTH2) — preferred

Mail clients that support the XOAUTH2 / OAUTHBEARER SASL mechanism
(Thunderbird, K-9 Mail, Apple Mail, ...) authenticate via Kanidm's OAuth2
authorization-code flow. The user logs into Kanidm with their full credentials
(including MFA) in a browser, and the mail client receives an access token
that it presents to Dovecot/Postfix via XOAUTH2. Dovecot validates the token
by calling Kanidm's OIDC userinfo endpoint. **No separate mail password is
required** — the user's Kanidm login authorises the mail client once, and the
client caches/refreshes the token automatically.

The `mail` OAuth2 client is declared in `kanidm.nix` (public, PKCE,
`enableLocalhostRedirects = true`). Only members of the `mail_users` group
receive `openid email profile` scopes; Dovecot extracts the `email` field
from the userinfo response as the IMAP/SMTP username.

#### Client setup (Thunderbird)

1. In Thunderbird: **Settings → Server Settings → Authentication Method →
   OAuth2** (and the same for the outgoing SMTP server).
2. Configure a custom OAuth2 server (or use `autoconfig` if your
   Thunderbird build reads `/.well-known/autoconfig`):
   - **Issuer:** `https://idm.minnecker.com`
   - **Client ID:** `mail`
   - **Client Secret:** *(empty — public client)*
   - **Authorization endpoint:** `https://idm.minnecker.com/ui/oauth2`
   - **Token endpoint:** `https://idm.minnecker.com/oauth2/token`
   - **Redirect:** `http://localhost:<port>` (any loopback port, allowed by
     `enableLocalhostRedirects`)
   - **Scopes:** `openid email profile`
3. On the next connection, Thunderbird opens a browser window to Kanidm.
   Log in (with MFA), authorise, and Thunderbird stores the token.

### PLAIN / LOGIN (legacy + webmail)

Clients that don't support XOAUTH2 (e.g. Roundcube webmail, older clients)
fall back to PLAIN auth. Dovecot validates the password via an LDAP bind to
Kanidm using the user's **POSIX password** (`kanidm person posix set-password`).
This is a separate, single-factor credential by design — Kanidm does not
expose the primary (MFA) password over LDAP.

---

## 🛠️ Step-by-Step Directory Setup (Examples)

### 1. Grant Mail Access
The `mail_users` group is auto-provisioned in `kanidm.nix`. Add the user:
```bash
kanidm -D idm_admin group add-members mail_users <username>
```

### 2. Set the user's mail attribute
```bash
kanidm -D idm_admin person update <username> --mail <user>@minnecker.com
```

### 3. (Legacy PLAIN auth only) Set a POSIX password
Only needed for clients that don't support XOAUTH2:
```bash
kanidm -D idm_admin person posix set-password <username>
```

---

## 🚀 Mail Server Secrets Setup

The Dovecot/Postfix LDAP configuration files are **auto-provisioned** — no
manual token generation step is required.

1. **Token generation (automatic):**
   `nixidm` generates a `mail_token` API token on Kanidm start via the
   `kanidm-mail-token` systemd service (REST API auth as `idm_admin`). The
   existing token is validated first via an LDAP bind+search; it is only
   regenerated when genuinely invalid (e.g. after a DB restore), avoiding
   desync with consumers that cache it. The token is written to
   `/var/lib/secrets/mail/ldap/ldap-token` on the shared NAS mount.

2. **Config rendering (automatic):**
   On `nixmail`, the `mail-ldap-config` systemd service runs before Dovecot
   and Postfix. It reads the shared token and renders:
   - `/var/lib/secrets/mail/dovecot/ldap-password.txt`
   - `/var/lib/secrets/mail/postfix/ldap-*.cf` (recipients, aliases, senders, catchalls, domains)

3. **Proxmox mounts required:**
   - `nixidm`: `/mnt/pve/nas/shared/secrets/mail/ldap` → `var/lib/secrets/mail/ldap` (`rw`) — isolated subdir only
   - `nixmail`: `/mnt/pve/nas/shared/secrets/mail` → `var/lib/secrets/mail` (`rw`) — full mount (reads `ldap/` subdir, writes dovecot/postfix)

   The `ldap` subdir must exist on the NAS before the first deploy:
   ```bash
   mkdir -p /mnt/pve/nas/shared/secrets/mail/ldap
   ```

4. **Direct client connections:**
   Clients connect directly to `nixmail` via host-level port forwarding
   (25, 143, 465, 587, 993). Dovecot and Postfix handle TLS termination
   themselves. The nginx mail proxy on `nixnginx` has been removed — it
   could not pass XOAUTH2 through to Dovecot.

5. **Rebuild:**
   ```bash
   nixos-rebuild switch
   ```


