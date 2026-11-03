# NixOS Mail Server Configuration (`nixmail`)

This directory contains the NixOS configuration files for the mail server container (`nixmail`), which runs Postfix and Dovecot integrated with a local Kanidm identity provider for dynamic authentication and mail routing.

## 📐 Architecture & Lookup Logic

All user configuration, aliases, catch-alls, and valid domains are configured dynamically in the identity provider (Kanidm) via LDAP queries, keeping the mail server state-free.

1. **Virtual Mailbox Domains:** Valid email domains are looked up dynamically using the LDAP filter `(mail=*@%s)`. If any account in Kanidm has an email address ending in `@domain.com`, Postfix automatically accepts `domain.com` as a valid virtual mailbox domain.
2. **Mailboxes & Aliases:** Valid recipient addresses are matched against the `mail` attribute of users who are members of the `mail_users` group.
3. **Catch-All Routing (Wildcards):** Postfix first queries for the specific email address (e.g. `user@domain.com`). If it doesn't exist, it queries the catch-all LDAP map for `mail=*@domain.com`. Setting `*@domain.com` as an alias on a user in Kanidm will route all unmatched mail for that domain to them.

---

## 🔀 Secondary addresses: aliases, logins and shared mailboxes

A Kanidm account may carry several `mail` values — typically the canonical
`<user>@minnecker.com` plus one or more legacy addresses on the other
family domains.  Nothing links those values to each other in the mail server;
they are simply several names for one account, and each consumer resolves them
differently:

* **Postfix** matches any `mail` value and rewrites it through
  `ldap-aliases.cf` (`mail=%s` → `uid` → `%s@minnecker.com`).  Because
  `virtual_alias_maps` is consulted *before* `virtual_mailbox_maps`, mail to a
  secondary address has always been rewritten to the canonical mailbox.
  Check any address with:

  ```bash
  postmap -q someone@legacy.example \
    ldap:/var/lib/secrets/mail/postfix/ldap-aliases.cf
  ```

  A secondary address that resolves to *nothing* is not an account at all and
  falls through to the `@domain` catch-all in `mapFiles."catchall"`.

* **Dovecot** authenticates on any `mail` value as well, but it derives the
  storage path from the *login string*
  (`mail_path = /var/vmail/%{user|domain|lower}/%{user|username|lower}/maildir/`).
  That is the gap: logging in with a secondary address authenticated against
  the real account and then opened a path that had never been created — an
  empty mailbox that looks exactly like deleted mail.  Nothing was ever stored
  under those paths, so there was no mail to move.

  `systemd.services.mail-alias-mailboxes` closes it.  Every 5 minutes it reads
  all `mail` values from LDAP, treats the `@minnecker.com` value of an account
  as canonical, and symlinks each other address to the canonical Maildir, so
  any address of an account opens the same mailbox.  It then subscribes the
  whole folder tree for that identity (see *"Many mails missing" below* — an
  unsubscribed folder is an invisible folder).  Stale links for removed
  addresses are pruned; only top-level `maildir` **symlinks** are candidates,
  so real mailboxes (directories) can never be matched.  If the LDAP query
  returns nothing, the unit exits without touching anything.

  Symlinks rather than `auth_username_maps` on purpose: a broken username map
  locks every user out of IMAP, a broken link affects a single address.

* **Do not delete secondary `mail` values to "clean this up".**  They are what
  makes those addresses valid recipients; remove one and the `@domain`
  catch-all starts routing that mail to florian instead.

**Shared mailboxes** are a separate, deliberate mechanism: Kanidm groups named
`mail_shared_<owner>` (the owner's mailbox is `<owner>@minnecker.com`).  Each
member gets a `.mail_shared.<owner>` symlink inside their own Maildir, mirrored
sub-folders for the same reason as above, and a Dovecot ACL.  Because an alias
Maildir is the *same directory* as the canonical one, alias logins inherit the
owner's shares automatically.

Both units are driven entirely by LDAP and contain no personal data in this
repository.  To see the current state:

```bash
systemctl status mail-alias-mailboxes mail-shared-mailboxes
find /var/vmail -mindepth 3 -maxdepth 3 -type l -name maildir   # alias links
find /var/vmail -type l -name '.mail_shared.*'                  # shared links
```

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
IMAP/SMTP unattended **must** use PLAIN.  `server@minnecker.com` is such an
account: Paperless-ngx polls it for documents (see `nixpaperless/README.md`).
Two things are needed, and neither is obvious:

1. **The account must be POSIX-enabled.**  Kanidm refuses LDAP simple bind for
   an account without the posix extension, and `posix set-password` on its own
   does not add it.  `person posix set` without arguments is enough — Kanidm
   allocates the `gidnumber` and a matching group by itself:

   ```bash
   kanidm -D idm_admin person posix set server
   kanidm -D idm_admin person posix show server     # must print a gidnumber
   ```

2. **The account needs a POSIX password**, and setting it is the awkward part.
   `kanidm person posix set-password` insists on a tty and reads the password
   itself, so it cannot be scripted with a plain pipe.  Two ways that work:

   Interactively, or with a pty:

   ```bash
   export HOME=/root SHELL=/run/current-system/sw/bin/bash
   script -qec 'kanidm -D idm_admin person posix set-password server' /dev/null
   ```

   (`SHELL` has to point at a real bash — NixOS has no `/bin/sh` or
   `/bin/bash`, and `script` fails without it.  It then asks for the password
   twice.  Note the CLI also needs a *valid idm_admin session*; a stale one
   aborts with `not a terminal`, which reads like a pty problem and is not
   one.  Piping the password into `script` just hangs.)

   Fully non-interactive over the REST API — the reliable path, no tty needed.
   Authenticate as `idm_admin` with the three-step `/v1/auth` flow (see
   `kanidm-mail-token` in `nixidm/kanidm.nix`), then:

   ```bash
   # PUT, not POST: POST/PATCH on this path return 405.
   # The body key is "value", not "password"; a wrong key gives a 422 that at
   # least names the field it wanted.
   curl -sk -b "$JAR" -H "Authorization: Bearer $BEARER" \
     -H 'Content-Type: application/json' \
     -X PUT "$API/v1/person/server/_unix/_credential" \
     -d '{"value":"<posix password>"}'
   ```

   Verify from outside, which also proves the Dovecot LDAP bind path:

   ```bash
   python3 -c 'import imaplib; m=imaplib.IMAP4_SSL("mx.minnecker.com",993); \
     print(m.login("server@minnecker.com", open("/dev/stdin").read().strip()))'
   ```

The password lives in exactly one place besides Kanidm: the
`paperless_mail_mailaccount` row in the Paperless database, which is what the
fetcher authenticates with.  Both sides currently hold the *original*
credential the old install used, recovered during the 2026-11-02 migration
from `paperless_mail_mailaccount.id=1` on saver CT 110 — the value was never
invented, and Kanidm and Paperless were written with the same string in the
same step.  If the two drift apart the symptom is upstream and
easy to miss — Paperless logs `MailError: Error while authenticating account
server@minnecker.com` every 10 minutes while the mailbox itself is perfectly
reachable.  Verify directly with IMAP, and re-sync the DB row after a rotation:

```bash
python3 -c 'import imaplib; m=imaplib.IMAP4_SSL("mx.minnecker.com",993); \
  print(m.login("server@minnecker.com", open("/dev/stdin").read().strip()))'
```

Note that **no other account in this deployment is POSIX-enabled** — every
human uses XOAUTH2 — so `server` is deliberately the only single-factor
mailbox.  Keep it that way: a POSIX password is a weaker credential and it
grants nothing but mail access to that one mailbox.

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

### Arrival dates (2026-11-02)

After the copy, 439 messages in florian's mailbox reported an IMAP internal
date **newer** than their own `Date:` header — 277 of them stamped 2020-10-25,
which is the day the archive was bulk-imported at the previous provider, while
still containing mail from 2017.  The maildir file name encodes the arrival
time, so those files were renamed to the header time (`mv`, same directory,
same `:2,FLAGS` suffix) followed by `doveadm force-resync`.  Rule applied:
rename when the header is more than two days older than the encoded time; the
generated rename list is what makes it reversible.

Measured over all 57 275 messages, not a sample:

* **0** messages had an internal date *older* than their `Date:` header, so the
  copy never stamped anything as older than it is — worth knowing before
  chasing that theory again.
* 14 messages (recent, in `.Trash`) carried a malformed timezone,
  `-0-300` instead of `-0300`.  Clients that cannot parse a `Date` fall back to
  an epoch date, so these are the ones that genuinely render as ancient.  The
  header was rewritten and the now-stale `,S=…,W=…` stat keys dropped from the
  file name so Dovecot re-stats the file.

Two things that look like bugs and are not:

* **`Date:` header vs internal date.**  Clients normally display the header.
  Re-stamping changes `INTERNALDATE` and arrival-order sorting only.
* **UID order.**  Mail that had already been delivered on `nixmail` kept its
  UIDs (florian's INBOX: 267–395, 19 Oct → 2 Nov) and the 2 443 migrated
  messages were appended after them (396–2881, spanning 2020-10-25 →
  2026-10-19), because Dovecot assigns UIDs in the order it discovers files.
  Old mail therefore looks "newer" to anything that orders by UID, and clients
  treat it as freshly arrived.  It is not an IMAP error.  Fixing the order
  would mean bumping `UIDVALIDITY` per folder, which forces every client to
  re-download everything (~13 GB for one mailbox) — deliberately not done.
  Migrated mail arrives `\Seen`, so it does not show up as unread.

### "Many mails missing" - they were folders, not messages (2026-11-03)

Reported right after the copy.  Nothing had been lost: all 56 257 source
messages were compared md5-by-md5 against the destination and the content is
complete (see the next section).  What was missing was the *folder list*,
because IMAP has two views of a mailbox tree and the migration only populated
one of them:

* `LIST` walks the maildir tree - what actually exists on disk.
* `LSUB` reads the per-user `subscriptions` file - what a mail client
  displays.  Thunderbird, Apple Mail and most webmail UIs build the folder
  pane from `LSUB` alone, so an unsubscribed folder and everything inside it
  simply do not exist as far as the client is concerned.

The copy carried messages and Dovecot index files but not `subscriptions`, so
each account kept only the handful of folders it had subscribed on `nixmail`
before the migration and the entire imported tree stayed hidden:

| account (`@minnecker.com`) | folders on the server | visible before | visible after |
| --- | --: | --: | --: |
| florian | 724 | 115 | 722 |
| helena  | 207 |  58 | 207 |
| travel  |  47 |   4 |  47 |
| sabine  |  26 |  19 |  26 |
| bodo    |  17 |  16 |  17 |
| minni   |  14 |   6 |  16 |
| carolin |  10 |   1 |  10 |
| server  |   2 |   0 |   2 |

Fixed through the supported API, one call per folder (1 047 calls, 0
failures):

```bash
doveadm mailbox list -u florian@minnecker.com |
  while IFS= read -r mb; do
    doveadm mailbox subscribe -u florian@minnecker.com "$mb"
  done
```

Two entries stay out of `LSUB` on purpose: `Migration-2026-11` and
`mail_shared` are `\Noselect` parents, and Dovecot never reports a
`\Noselect` mailbox as subscribed.  Their children are subscribed, so clients
render them normally.  `minni` has two *extra* entries (`plus`, `something`)
left over from folders deleted on `nixmail` before the migration - they exist
on neither side and are cosmetic.

Diagnosing this without guessing, from inside CT 103: log in over IMAP as the
user with the master user (`<user>*mailapi`, password in
`/run/dovecot-auth/master-users`, see the Authentication section) and compare
the `LSUB` and `LIST` counts.  `LSUB < LIST` means hidden mail.  Note that the
`curl` in this image has no IMAP support; speaking IMAP over the loopback
plaintext port (`auth_allow_cleartext = yes`) works.

### Six messages that really were missing (2026-11-03)

The full-tree md5 comparison found five messages present on `saver` and absent
on `nixmail`, all in `minni`'s `INBOX`, all unseen, dated 19-21 Oct 2026.  The
warning Dovecot printed when they were re-installed explains the mechanism:

```
Mailbox INBOX: Expunged message reappeared, giving a new UID (old uid=842, ...)
```

They *had* been copied and indexed (UIDs 842-846) and were then expunged
again, because a later pass removed the files from disk while the index still
knew them - the classic symptom of a second sync run with a narrower file
list.  They were restored from `saver` into
`/var/vmail/minnecker.com/minni/maildir/new/` (additive only, existing files
skipped, `dovecot:dovecot` `0600`); `INBOX` went 810 to 815 and the content
hashes match the source byte for byte.

A sixth message sat outside the reach of the migration entirely.  `mail_path`
changed on `saver` at some point, so florian's home directory also holds an
orphan `.Drafts/` belonging to the previous layout.  Dovecot cannot see it at
all - it is outside `mail_location`, so `doveadm` never lists it and no
`dsync`/LDA pass could ever have copied it.  It contains one 343-byte draft
(`test`, 10 Jan 2026), now moved into
`/var/vmail/minnecker.com/florian/maildir/.Drafts/cur/` under a valid maildir
name; `Drafts` is 257 messages.

With both fixes applied the copy is exact.  Every message that exists anywhere
on `saver`, including the one Dovecot could not address, is present on
`nixmail`.  The only 14 remaining content differences are the `-0-300`
timezone repairs from 2026-11-02, each confirmed by matching the microsecond
and pid part of its maildir file name on both sides.

### Rollback

The source tree on `saver` was only ever read.  To go back, point the MX record
and `oldmail.minnecker.com`-style client settings at `saver` again — no data
was consumed or rewritten by the migration.
