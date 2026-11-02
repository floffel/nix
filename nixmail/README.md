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

#### Unattended services (Paperless-ngx auto-purge, scripts, …)

A service cannot run an OAuth2 browser flow, so anything that logs in over
IMAP/SMTP unattended **must** use PLAIN and therefore needs a POSIX password on
its account.  `server@minnecker.com` is such an account: Paperless-ngx polls it
for documents (see `nixpaperless/README.md`).  Set it interactively from inside
CT 105 — the Kanidm CLI insists on a tty and reads the password itself, so it
cannot be scripted:

```bash
pct exec 105 -- kanidm -D idm_admin person posix set-password server
```

If the password is missing or wrong, the symptom is upstream: Paperless logs
`AUTHENTICATIONFAILED` for its auto-purge run every 10 minutes while the
mailbox itself is perfectly reachable.

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
   `/var/lib/secrets/mail/ldap/ldap-token`, which is a directory on the Proxmox
   host's own disk, bind-mounted into both producers and readers.

2. **Config rendering (automatic):**
   On `nixmail`, the `mail-ldap-config` systemd service runs before Dovecot
   and Postfix. It reads the shared token and renders:
   - `/var/lib/secrets/mail/dovecot/ldap-password.txt`
   - `/var/lib/secrets/mail/postfix/ldap-*.cf` (recipients, aliases, senders, catchalls, domains)

3. **Proxmox mounts required:**

   `mail` is one of the secret groups that is shared between containers, so it
   lives on the **Proxmox host's own disk** under `/var/lib/secrets/mail` and is
   bind-mounted per container.  (The NFS share that used to hold it,
   `/mnt/pve/nas/shared/secrets`, was retired on 2026-11-01 — see the
   "Secrets" chapter of the top-level `README.md`.)

   ```text
   # nixidm (CT 105) — writes the token, isolated subdir only
   lxc.mount.entry: /var/lib/secrets/mail/ldap var/lib/secrets/mail/ldap none bind,rw 0 0
   # nixmail (CT 103) — reads ldap/, writes dovecot/ + postfix/
   lxc.mount.entry: /var/lib/secrets/mail var/lib/secrets/mail none bind,rw 0 0
   lxc.mount.entry: /var/lib/secrets/ssl var/lib/secrets/ssl none bind,ro 0 0
   ```

   The `ssl` mount carries the TLS certificates that Dovecot and Postfix use now
   that they terminate TLS themselves (the nginx mail proxy was removed because
   it could not pass XOAUTH2 through to Dovecot).

   Both directories must exist on the host before the container starts, and the
   `mail` tree must be owned by the uid the container maps `dovecot`/`kanidm` to
   — otherwise LXC refuses to start the container (a bind source that does not
   exist is fatal) or the writer cannot create its files:

   ```bash
   mkdir -p /var/lib/secrets/mail/ldap
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



---

## 📦 Migration from `saver` (2026-11-02)

The mailboxes that had lived on the old server (`saver`, Dovecot on CT 113,
Debian) were moved to `nixmail` before the MX switch.  **17.86 GB / 57 082
files across 8 mailboxes**, all per-file verified afterwards; the source tree
was never modified, so the move is still reversible.

### Where the mail lives

`nixmail` uses Dovecot 2.4's `mail_driver = "maildir"` with

```
mail_home = /var/vmail/%{user | domain | lower }/%{user}/
mail_path = /var/vmail/%{user | domain | lower }/%{user | username | lower }/maildir/
```

so a mailbox is `/var/vmail/<domain>/<user>/maildir/` with `cur/`, `new/`,
`tmp/`, owned by `dovecot:dovecot`, directories `0700` and files `0600`.  Note
the two variables differ: `mail_home` keeps the *full* address, which is where
Sieve sits (`/var/vmail/minnecker.com/florian@minnecker.com/sieve/`), while
`mail_path` lowercases the local part for the maildir itself.  Both paths are
correct and both directories legitimately exist — an "extra"
`<user>@<domain>/` directory holding only `sieve/` is not stray mail.

### Address mapping

| source | destination |
| --- | --- |
| `florian`, `helena`, `travel`, `server`, `sabine`, `bodo` @`minnecker.com` | unchanged |
| `minni`, `carolin` @`sbminnecker.de` | same local part on `minnecker.com` |
| orphan mailboxes with no account (`3m5`, `3m5backend`, `floffel`, …) | folders `.Migration-2026-11.*` under the owning account |

The orphan mailboxes became folders rather than accounts because **Kanidm
account ids may not begin with a digit**, so `3m5` and `3m5backend` cannot be
provisioned as identities at all.  If one of them ever needs to be a real
mailbox again, create an account with a letter-initial id and give it the old
address as a mail alias.

### How the copy was done

`/tmp/mail-sync.py` (on the laptop) drives a resumable copy: for each mailbox it
pipes a `tar` stream and extracts with **`tar -k`**, which skips files that
already exist.  A run can therefore be interrupted and restarted any number of
times without deleting anything first.  Throughput over the saver→laptop relay
was ≈3.5 MB/s; `saver` (`172.16.16.1`) is reachable **only from the laptop** —
`px` has no route to it, so the copy cannot be done host-to-host.

#### The trap: folder-level skipping is not enough

The first pass compared *folder* counts and byte totals and declared itself
complete, yet individual messages were missing: a folder whose aggregate size
matched could still differ file by file.  Verify per file, not per folder:

- `/tmp/mail-verify.py [users…]` — builds a sorted `size\tpath` list on both
  sides and diffs them, writing `/tmp/mailverify/<user>.{missing,truncated,dstonly}`.
- `/tmp/mail-repair.py [users…]` — re-copies exactly the flagged files
  (overwrite intended).  The correct tar form for "these paths, not their
  contents recursively" is
  `tar cf - --no-recursion -C <root> -T -`; putting `--no-recursion` between
  `cf` and `-` makes it parse as a file name and silently do nothing useful.

Repairs found this way: florian 3 truncated, helena 3 missing, sabine 16
missing, server 1 (`maildirfolder` marker).  After re-verification: **0 missing
and 0 size mismatches for all 8 mailboxes.**

### After the copy

1. **Ownership/permissions** — `/root/mailimport/post.sh`: `chown -R
   dovecot:dovecot`, directories `0700`, files `0600`.
2. **Rebuild the indexes** — Dovecot 2.4 renamed `force-rescan` to
   `force-resync`, so the usual recipe fails with an unknown command:

   ```bash
   doveadm force-resync -u <user>@minnecker.com '*'
   ```

   Run for all 8 users; it is silent on success.
3. **Confirm over IMAP** that the migrated folders are visible, then check the
   mailbox counts.  Message counts before → after (the increase is the
   `.Migration-2026-11.*` folders plus mail that arrived after the MX flip):

   | user | before | after |
   | --- | --- | --- |
   | florian | 655 | 724 |
   | helena | 158 | 207 |
   | sabine | 5 | 26 |
   | travel | 45 | 47 |
   | minni | 10 | 14 |
   | bodo | 1 | 17 |
   | carolin | 10 | 10 |
   | server | 2 | 2 |

Files that exist **only** on the destination are expected and are not a
migration artefact: they are mail delivered on `nixmail` after the MX switch
recognisable by the `.nixmail` hostname suffix in the filename, plus the
folders Dovecot creates for every account by default.

### Rollback

The source tree on `saver` was only ever read.  To go back, point the MX record
and `oldmail.minnecker.com`-style client settings at `saver` again — no data
was consumed or rewritten by the migration.
