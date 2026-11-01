# Proxmox NixOS Guest Containers Setup Guide

This repository contains a unified NixOS configuration for running services (such as a mail server, database, LDAP directory, monitoring stack, etc.) as unprivileged Proxmox LXC containers.

---

## ⚠️ Never stop CT 100 (`nixwireguard`) from a remote session

CT 100 is the WireGuard gateway **and** the network path used to reach the
Proxmox host and the SMB/NFS storage that many containers and the host depend
on. Running `pct stop`, `pct reboot`, `pct shutdown`, or `pct reset` on CT 100
over a remote SSH session can cut **all** access and deadlock storage mounts;
the host may then appear completely unreachable. Only use an out-of-band
console and a planned maintenance window.

Never add a mount entry to CT 100 whose source is only reachable through
CT 100. Mount changes are applied on container start and can create a boot
deadlock. If CT 100 is already down, see the recovery steps in
[`AGENTS.md`](AGENTS.md#if-ct-100-is-already-down). Any start/stop/reboot that
can affect the edge must be run detached with `systemd-run`, never in the SSH
session that the edge provides.

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

> **Upgrading all containers:** take snapshots, build every container first
> (`nix-channel --update`, then `nixos-rebuild build`), and only then switch
> in dependency order. Do not run `nixos-rebuild switch --upgrade` on every
> container blindly. See [UPGRADE.md](UPGRADE.md) for the full procedure,
> pitfalls (Kanidm EOL upgrades, Open WebUI build memory, Postfix transport)
> and verification commands.

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

#### Where secrets live: host disk vs NAS share

Two rules, decided per secret:

* **Shared between containers** → the Proxmox host's **own disk**, under
  `/var/lib/secrets/<group>/<consumer>`, bind-mounted into every container that
  needs it (the writer `rw`, the readers `ro`).  Everything Matrix reads lives
  there since 2026-10-31, which is why `nixmatrix` has **no NAS dependency at
  all** anymore (`mount | grep mnt/pve/nas` inside CT 109 is empty).
* **Used by exactly one container** → inside that container's own filesystem
  under `/var/lib/secrets/<name>`, with no mount entry at all.  Examples: the
  Garage S3 keys in `nixmatrix:var/lib/secrets/matrix/s3` and
  `nixnginx:var/lib/secrets/s3/nextcloud`, Vaultwarden's admin token, Wiki.js'
  admin password, MAS's own signing keys.

The NAS (`/mnt/pve/nas`, NFS `192.168.1.203:/mnt/big/remote`) still carries the
other groups.  Moving a group is per-subdir: `nixpostgres` and `nixidm` keep
their NAS parent mount and simply get the `matrix` subdir bind-mounted **on
top** of it, so one consumer can move without touching its siblings.  Put the
nested line after its parent in the config file, and remember that mount
entries only take effect on container **start** (`pct stop` + `pct start`).

**Status as of 2026-10-31 (done):** CT 105 and CT 107 have been restarted and
both nested overrides are verified live — a probe file written inside lands on
the host disk and never on the NAS — so `/mnt/pve/nas/shared/secrets/oauth2/matrix`
and `/mnt/pve/nas/shared/secrets/postgres/matrix` have been deleted. Matrix now
has **no NAS dependency anywhere**: `nixmatrix` boots with
`mount | grep -c mnt/pve/nas` = `0` (re-verified after the deletion with a full
container restart), and `nixidm`/`nixpostgres` write their Matrix secrets to the
host disk. Rollback material lives on the host at
`/root/backups/secrets-nas-matrix-20261031/` (secret copies + both `.conf`
files) plus the ZFS snapshots `pre-hostdisk-20261031` on CT 105 and CT 107.

**Ownership is the part that bites.** All these containers are unprivileged and
share one uid mapping (container root = host uid `100000`, `0 100000 65536`),
which behaves differently from the NAS:

* A file written by container root lands on the host as uid `100000` and shows
  up as `root:root` inside *every* container — so `0600` already suffices for a
  root-run consumer.  On the NAS the export squashes everything to host `root`,
  which is *unmapped* inside the containers, so files appear as
  `nobody:nogroup` and only the world-readable bit made them usable.
* Seeded files must be owned by `100000`, not by host `root`, otherwise no
  container can rewrite them.
* When the writer's unit drops privileges, the directory must belong to **that**
  uid: `postgresql-password-provisioning` runs as `postgres` (uid 71 in
  CT 107), so `/var/lib/secrets/postgres/matrix` is owned by host `100071`.
  Getting this wrong surfaces as `chmod: changing permissions of
  '/var/lib/secrets/postgres/matrix/db-password': Operation not permitted`.
* Never `chown` a shared file to a service user — `coturn` did exactly that to
  the mirrored TURN secret, which would have made it unreadable for Synapse's
  root-run config unit and silently substituted `PLACEHOLDER` for the real
  value.  It now chowns the mirrored copy to `root` (see `nixnginx/nginx.nix`).

Seeding a host-local group looks like this (then change **only the source**
path in `/etc/pve/lxc/<id>.conf` and restart the container):

```bash
install -d -m 755 -o 100000 -g 100000 /var/lib/secrets/coturn
install -m 644 -o 100000 -g 100000 \
  /mnt/pve/nas/shared/secrets/coturn/shared-secret /var/lib/secrets/coturn/shared-secret
chown -R 100071:100071 /var/lib/secrets/postgres/matrix   # writer runs as postgres
```

**Rollback.** Mount entries live only in `/etc/pve/lxc/<id>.conf`; the
pre-change copies are on the host in `/root/backups/secrets-off-nas-20261031/`.
Restore the file, `pct stop <id> && pct start <id>`, done.  The NAS copies were
**copied, not moved**, and are byte-identical (`md5sum` verified), so a rollback
is lossless — but note they are now dead copies that nothing reads, and if one
is ever deleted while a writer still points at the NAS, that writer regenerates
a *fresh* value there and the two sides diverge silently (SSO or DB auth breaks
on the next consumer restart).

**Caveat:** `/var/lib/secrets` is on the host's root filesystem, which is not
part of the NAS backup.  It holds ~5 small files; snapshot or back it up
alongside the host config.

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
| `nixidm` | `/mnt/pve/nas/shared/secrets/oauth2` | `var/lib/secrets/oauth2` | `rw` | Provisions every OAuth2 client secret except Matrix (sole writer) |
| `nixidm` | **`/var/lib/secrets/oauth2/matrix`** *(host disk)* | `var/lib/secrets/oauth2/matrix` | `rw` | Nested override (live since 2026-10-31): the Matrix MAS client secret lives on the host, the other clients stay on the NAS |
| `nixforgejo` | `/mnt/pve/nas/shared/secrets/oauth2/forgejo` | `var/lib/secrets/oauth2/forgejo` | `ro` | Forgejo OIDC client secret |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/oauth2/nextcloud` | `var/lib/secrets/oauth2/nextcloud` | `ro` | Nextcloud OIDC client secret |
| `nixmonitoring` | `/mnt/pve/nas/shared/secrets/oauth2/grafana` | `var/lib/secrets/oauth2/grafana` | `ro` | Grafana OIDC client secret |
| `nixmatrix` | **`/var/lib/secrets/oauth2/matrix`** *(host disk)* | `var/lib/secrets/oauth2/matrix` | `ro` | Matrix MAS client secret (`mas-secret`); the legacy `secret` file is unused and was not carried over |

| `nixvaultwarden` | `/mnt/pve/nas/shared/secrets/oauth2/vaultwarden` | `var/lib/secrets/oauth2/vaultwarden` | `ro` | Vaultwarden OIDC client secret |
| `nixwikijs` | `/mnt/pve/nas/shared/secrets/oauth2/wikijs` | `var/lib/secrets/oauth2/wikijs` | `ro` | Wiki.js OIDC client secret (seeded into the `authentication` table by `wikijs-provision`) |
| `nixpostgres` | `/mnt/pve/nas/shared/secrets/postgres` | `var/lib/secrets/postgres` | `rw` | Provisions every DB role password except the Matrix pair (sole writer) |
| `nixpostgres` | **`/var/lib/secrets/postgres/matrix`** *(host disk)* | `var/lib/secrets/postgres/matrix` | `rw` | Nested override (live since 2026-10-31) for the Matrix/MAS role passwords; owned by `100071` because the writer runs as `postgres` |
| `nixforgejo` | `/mnt/pve/nas/shared/secrets/postgres/forgejo` | `var/lib/secrets/postgres/forgejo` | `ro` | Forgejo DB password |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/postgres/roundcube` | `var/lib/secrets/postgres/roundcube` | `ro` | Roundcube DB password |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/postgres/nextcloud` | `var/lib/secrets/postgres/nextcloud` | `ro` | Nextcloud DB password |
| `nixmatrix` | **`/var/lib/secrets/postgres/matrix`** *(host disk)* | `var/lib/secrets/postgres/matrix` | `ro` | Matrix DB passwords (`db-password`, `mas-db-password`) |
| `nixvaultwarden` | `/mnt/pve/nas/shared/secrets/postgres/vaultwarden` | `var/lib/secrets/postgres/vaultwarden` | `ro` | Vaultwarden DB password |
| `nixwikijs` | `/mnt/pve/nas/shared/secrets/postgres/wikijs` | `var/lib/secrets/postgres/wikijs` | `ro` | Wiki.js DB password |
| `nixforgejo` | `/mnt/pve/nas/shared/secrets/forgejo` | `var/lib/secrets/forgejo` | `rw` | Forgejo Actions runner registration token |
| `nixopenwebui` | `/mnt/pve/nas/shared/secrets/open-webui` | `var/lib/secrets/open-webui` | `rw` | Open WebUI env (LLM URLs, PKCE client) |
| — | *(not configured)* | `var/lib/secrets/matrix` | local | Synapse runtime dir **inside CT 109's own filesystem**; holds the Garage S3 keys in `s3/` (see the nixmatrix section) |
| `nixvaultwarden` | `/mnt/pve/nas/shared/secrets/vaultwarden` | `var/lib/secrets/vaultwarden` | `rw` | Vaultwarden env (DB url, admin token) |
| `nixwikijs` | `/mnt/pve/nas/shared/secrets/wikijs` | `var/lib/secrets/wikijs` | `rw` | Wiki.js admin password (generated locally by `wikijs-provision`) |
| `nixnsd` | `/mnt/pve/nas/shared/secrets/nsd` | `var/lib/secrets/nsd` | `rw` | NSD TSIG sync key |
| `nixnginx` | `/mnt/pve/nas/shared/secrets/nginx` | `var/lib/secrets/nginx` | `ro` | Nextcloud/Roundcube DB pws, Roundcube DES key |
| `nixnginx` | **`/var/lib/secrets/coturn`** *(host disk)* | `var/lib/secrets/coturn` | `rw` | Coturn TURN shared secret (generated by the `coturn-secret` activation script, mirrored for `nixmatrix`) |
| `nixmatrix` | **`/var/lib/secrets/coturn`** *(host disk)* | `var/lib/secrets/coturn` | `ro` | Coturn TURN shared secret (read by Synapse for REST API auth) |

> The Nextcloud datadir used to be mounted here from the NAS
> (`/mnt/pve/nas/shared/nextcloud/data_new`).  It is **no longer a bind mount**:
> user file content lives in Garage S3, and the ~173 MB that remains
> (`config/`, `appdata_oc5veetcuvee/`, the `.ncdata` marker, per-user scratch)
> sits on `nixnginx`'s own ZFS volume.  See “Nextcloud user files on Garage S3”.

Example `lxc.mount.entry` lines (one per row above):
```ini
# Per-service secrets
lxc.mount.entry: /mnt/pve/nas/shared/secrets/forgejo var/lib/secrets/forgejo none bind,rw 0 0
# Shared SSL certificates
lxc.mount.entry: /mnt/pve/nas/shared/secrets/ssl var/lib/secrets/ssl none bind,ro 0 0
# Shared OAuth2 client secrets — nixidm gets the parent (rw), consumers get their own subdir (ro)
# nixmatrix instead reads from the host's own disk (no NAS dependency): see the section above
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2 var/lib/secrets/oauth2 none bind,rw 0 0
lxc.mount.entry: /var/lib/secrets/oauth2/matrix var/lib/secrets/oauth2/matrix none bind,rw 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2/forgejo var/lib/secrets/oauth2/forgejo none bind,ro 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2/vaultwarden var/lib/secrets/oauth2/vaultwarden none bind,ro 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/oauth2/wikijs var/lib/secrets/oauth2/wikijs none bind,ro 0 0
# Shared Postgres DB passwords — nixpostgres gets the parent (rw), consumers get their own subdir (ro)
# (nested override for the Matrix role passwords goes AFTER its parent)
lxc.mount.entry: /mnt/pve/nas/shared/secrets/postgres var/lib/secrets/postgres none bind,rw 0 0
lxc.mount.entry: /var/lib/secrets/postgres/matrix var/lib/secrets/postgres/matrix none bind,rw 0 0
lxc.mount.entry: /mnt/pve/nas/shared/secrets/postgres/forgejo var/lib/secrets/postgres/forgejo none bind,ro 0 0
# Coturn TURN shared secret — nixnginx writes (rw), nixmatrix reads (ro), both from the host disk
lxc.mount.entry: /var/lib/secrets/coturn var/lib/secrets/coturn none bind,rw 0 0
lxc.mount.entry: /var/lib/secrets/coturn var/lib/secrets/coturn none bind,ro 0 0
```

##### Nested bind mounts only change on container start — verify with a marker file

`lxc.mount.entry` lines are applied by LXC **when the container starts**, never
on `nixos-rebuild switch`, and a `pct set` alone changes nothing at runtime. That
matters for the two *nested* host-disk overrides above (`nixidm`'s
`oauth2/matrix` and `nixpostgres`'s `postgres/matrix`), which sit inside a NAS
parent that is mounted into the same container: until that container has been
stopped and started once, the parent NAS tree is still what the container reads,
the host-disk copy is inert, and the writer (`kanidm-provision`,
`postgresql-setup`) keeps writing to the NAS while `nixmatrix` reads the host
copy — i.e. the two halves of the same secret can silently drift apart, and a
rotation would break MAS/Synapse logins. So after changing these entries:
restart the container (`pct stop <id> && pct start <id>`; `pct restart --force`
prints a usage message and does nothing) and **verify**, in that order.

Do not trust `findmnt` here — asked about a mountpoint it happily reports the
shadowed child bind, which is exactly how this was missed once. Listing the
directory from inside the container is wrong too: a file created at
`/var/lib/secrets/oauth2/matrix/x` shows up there whichever filesystem is
behind it, so that test passes even when the override is dead (and the
`/mnt/pve/nas/...` half of it cannot even be created, because these containers
do not mount `/mnt/pve/nas` at all).

Write **from inside**, look **from the host** — exactly one branch may fire:

```bash
# all three lines run on the Proxmox host
pct exec 105 -- /run/current-system/sw/bin/bash -lc \
  'touch /var/lib/secrets/oauth2/matrix/.probe'
[ -e /var/lib/secrets/oauth2/matrix/.probe ] && echo "host disk -> override ACTIVE"
[ -e /mnt/pve/nas/shared/secrets/oauth2/matrix/.probe ] && echo "NAS -> still needs restart"
rm -f /var/lib/secrets/oauth2/matrix/.probe /mnt/pve/nas/shared/secrets/oauth2/matrix/.probe
```

Host disk means the override is active and the NAS copy is dead weight; NAS
means the container still needs its restart. For `nixmatrix` (CT 109), which
has no NAS entries at all, the check is simply
`mount | grep -c mnt/pve/nas` → must print `0`.

Note that `pct exec <id> -- sh -c` lands in a container whose `PATH` is not
set up, so `ls`/`touch` come back as "command not found"; use
`/run/current-system/sw/bin/bash -lc` and export a `PATH` first.

##### `pct config` is authoritative — the raw `.conf` file is not

`/etc/pve/lxc/<id>.conf` embeds one section per snapshot, headed by the bare
snapshot name in brackets (`[pre-s3-media-20261030]`), and each section holds
the `lxc.mount.entry` lines **as they were at snapshot time**. Grepping the raw
file therefore shows mounts that were removed long ago — misleading enough to
make a container look like it still needs a directory you just deleted. Use
`pct config <id>`, which prints only the live section. (Listing snapshots is
`pct snapshots <id>`; `pct snapshot list <id>` dies on parameter parsing, which
looks deceptively like "no snapshots".)

The flip side is a real rollback hazard: rolling a container back to an old
snapshot restores its old mount lines. The Matrix snapshots taken before
2026-10-31 still reference `/mnt/pve/nas/shared/secrets/{oauth2,postgres}/matrix`,
which no longer exists, and a non-`optional` bind whose source is missing makes
LXC refuse to start the container. Edit those lines out of the snapshot section,
or restore the directory from `/root/backups/secrets-nas-matrix-20261031/`,
before rolling back.

#### 🌙 Nightly backup of the host's own secrets

`/var/lib/secrets` is on the host's local disk and **no vzdump job covers it**
(vzdump backs up containers, not host files), yet without those files
`nixmatrix`/`nixpostgresql`/`nixidm`/`nixnginx` cannot start. `scratch/backup-host-secrets.sh`
closes that gap: it archives `/var/lib/secrets`, `/etc/pve/lxc` (the configs that
carry the bind-mount entries), `/etc/pve/storage.cfg` and `/root/backups` (the
pre-change LXC configs plus the archived copies of retired NAS shares) into a
zstd tar, writes it to `/var/backups/host-secrets/` *and* to
`/mnt/pve/nas/shared/host-backups/`, keeps the newest 14 of each, and fails
loudly if either copy is missing.

Install from the repo checkout on the host (`scratch/install-host-secrets-backup.sh`,
idempotent) — it installs the script as `/usr/local/sbin/backup-host-secrets.sh`,
installs `scratch/systemd/host-secrets-backup.{service,timer}`, and enables the
timer (`02:30` + up to 15 min jitter, `Persistent=true` so a missed night is
caught up; it deliberately avoids the 00:00 vzdump window). Manual run:
`systemctl start host-secrets-backup.service`.

Three properties are deliberate and worth keeping when editing the script:

* it **verifies the archive** (`zstd -t` + `tar -t`) and asserts that every
  requested path actually appears in it — a backup nobody can open is not a
  backup, and this is what catches a whole subtree going missing;
* it writes to `*.tmp` and renames, because `zstd` refuses to overwrite an
  existing file (a same-day retry would otherwise fail) and a crash must not
  leave a truncated archive under the final name;
* it uses `tar -h`, because `/etc/pve` is pmxcfs and `/etc/pve/lxc` is a symlink
  to `nodes/<node>/lxc` — without `-h` the archive silently contains **zero**
  `.conf` files. That was caught by the per-path assertion, not by luck.

Restore (note `-C /`, members are relative to `/`):

```bash
cd / && zstd -dc /var/backups/host-secrets/host-secrets-<date>.tar.zst | tar -xf -
# or a single file:
zstd -dc <archive> | tar -C /tmp/restore -xf - var/lib/secrets/postgres/matrix/db-password
```

The archives are plaintext, root-only (`0700`/`0600`), which matches the existing
posture: the NAS already holds full vzdump images of every container and the
remaining NAS secret shares. Encrypting them before they leave the host would be
an improvement, but needs a key that survives the host independently.

#### Mail hardening & email features

The `nixmail` container bind-mounts the `mail` secrets parent
(`/var/lib/secrets/mail`) **read-write**, so the extra mail secrets below need
no additional mount lines — they are generated/provisioned under the existing
mount:

| Path under `/var/lib/secrets/mail` | Provider | Purpose |
| :--- | :--- | :--- |
| `rspamd/controller-password` / `controller-enable-password` | `mail-rspamd-password` oneshot | plaintext controller passwords for the rspamd WebUI (note: `parsedmarc` needs **no** password — it reads reports from the postmaster Maildir on disk and sends the digest via unauthenticated localhost submission). |
| `dkim/minnecker.com.private` + `dkim/minnecker.dns` | `mail-dkim-key` oneshot | DKIM/ARC signing key (2048-bit) and a ready-to-paste DNS hint file. |

**Addressing (`recipient_delimiter = "+."`)**
`user+tag@minnecker.com` and `user.tag@minnecker.com` both reach the same
mailbox. A global `before` sieve auto-files them into `tags/<tag>/` (path
traversal is sanitised). In Roundcube you'll see a `tags` folder.

**Quarantine tier**
Rspamd adds `X-Rspamd-Quarantine: yes` to mail scoring ≥ 12 (below `reject =
40`). The routing sieve redirects that mail to `quarantine@minnecker.com` —
an alias to `postmaster@` (managed in Kanidm) — which the same sieve files
into the `Quarantine/` folder. Releasing a message = moving it out of
`Quarantine/` in IMAP. The loop guard: mail addressed to the quarantine
mailbox is filed into `Quarantine/` **before** the redirect rule, so a
re-submitted quarantined message never gets redirected again.

**Reports (DMARC / TLS-RPT)**
Aggregate report mail addressed to `reports@minnecker.com` (alias →
`postmaster@`, managed in Kanidm) is filed into the hidden `.Reports` folder.
`parsedmarc` (running on `nixmail` as the dovecot user) reads that Maildir
**directly from disk** — no IMAP/SMTP passwords — and emails a daily digest to
`florian@minnecker.com` via unauthenticated localhost submission (loopback is
in `mynetworks`). Processed reports are deleted. TLS-RPT requests point at
`reports@` via `_smtp._tls`.

**MTA-STS + TLS-RPT**
`https://mta-sts.minnecker.com/.well-known/mta-sts.txt` serves the policy
(`mx: mx.minnecker.com` primary + `mx: riese.minnecker.com` secondary during
the mail migration, mode enforce). During the cutover both hosts are listed in
the policy so STS-enforcing senders accept mail on either MX; once the
migration completes the old `riese` entry and its `MX 20` record are removed.
Records: `_mta-sts` TXT and `_smtp._tls` TXT (TLS-RPT) live in
`nixnsd/zones/minnecker.com.forward`.

**Rspamd WebUI**
`https://rspamd.minnecker.com` proxies to the rspamd controller and is gated
by the same nginx/LDAP auth as `ki.minnecker.com`. Scan history/graphs use the
local Redis.

**DKIM / ARC rotation**
The `mail-dkim-key` oneshot generates/owns the key. To rotate: remove
`minnecker.com.private`, let `mail-dkim-key` regenerate (or run it
manually), then paste the `minnecker._domainkey` and `arc._domainkey` TXT
records from `dkim/minnecker.dns` into the zone, bump the SOA serial, and
`nixos-rebuild switch` on `nixnsd`. The published key must match the key file
before cutting over. (The current in-zone key is 1024-bit and was hosted under
the wrong owner name `minnecker.com._domainkey`; both are fixed in the zone
source — a full rotation to 2048-bit should also be scheduled.)


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
  * The `password` line is **rewritten on every Synapse start** from `/var/lib/secrets/postgres/matrix/db-password` (written by `nixpostgres` into a **host-disk** bind mount, not the NAS — `nixmatrix` has no NAS mounts at all), so the value above is only the initial placeholder — it stays in sync with the role's actual password automatically.
  * The `client_secret`/`secret` lines are **rewritten on every Synapse start** from `/var/lib/matrix-authentication-service/client-secret` and `…/admin-token`, two random values that the `mas-secrets-config` unit generates into the container's own filesystem on first boot (they are used by MAS's native client registration, not by Kanidm — the Kanidm↔MAS client secret lives on the shared mount at `/var/lib/secrets/oauth2/matrix/mas-secret`), so the values above are only initial placeholders.
* **Media storage in Garage (S3)**: Matrix media (own uploads, downloaded remote media and their thumbnails) is kept in the Garage bucket `synapse`. `nixmatrix/synapse.nix` loads the `matrix-synapse-s3-storage-provider` plugin (`services.matrix-synapse.plugins`), and the `matrix-synapse-secrets-config` unit appends the provider block to `secrets.yaml` at runtime:
  ```yaml
  media_storage_providers:
    - module: s3_storage_provider.S3StorageProviderBackend
      store_local: true
      store_remote: true
      store_synchronous: true
      config:
        bucket: "synapse"
        region_name: "garage"
        endpoint_url: "http://192.168.1.132:3900"
        access_key_id: "<read from /var/lib/secrets/matrix/s3/access-key>"
        secret_access_key: "<read from /var/lib/secrets/matrix/s3/secret-key>"
  ```
  Garage answers the S3 API on `192.168.1.132:3900` (plain HTTP on the internal LAN, path-style addressing, region `garage`); an unauthenticated request returns `403`. Endpoint, bucket and region are declared once as `let` values at the top of `nixmatrix/synapse.nix`. `192.168.1.132` is reachable from `nixmatrix` (`10.20.20.19`).
  * **Mirror + offload, not a replacement — do not disable local storage**: `enable_local_media_storage` deliberately stays at its default `true`. S3-only would be nice and Synapse even supports the mode in principle (`media_repository.py` accepts "no local provider" when a remote provider is configured), but this plugin cannot write in that mode: `MediaStorage.store_into_file()` hands providers only the *relative* media path and writes bytes to disk *only* if a local provider exists — otherwise it writes a `tempfile.NamedTemporaryFile` whose name is never passed on — while the plugin rebuilds an absolute path as `media_store_path + path`. With `enable_local_media_storage: false` it therefore uploads a file that was never created: `FileNotFoundError: [Errno 2] …/media_store/local_content/<id>` → HTTP 500 on every `POST /_matrix/media/v3/upload` (Element: „Hochladen fehlgeschlagen“). That is upstream bug [synapse-s3-storage-provider#162](https://github.com/matrix-org/synapse-s3-storage-provider/issues/162), open since 2026-07 and still unfixed in v1.7.0; the proposed one-liner (`Filename=file_info.upload_path`) needs an attribute Synapse 1.163 does not expose (see element-hq/synapse#19903), so making it work would mean patching Synapse *and* the plugin. Object storage is therefore used the way the plugin documents it — mirror plus offload: `store_synchronous: true` writes the object to Garage *before* the upload is acknowledged (the bucket is complete at all times and `store_remote: true` serves anything ever stored), and the `matrix-synapse-s3-media-cleanup` timer runs the documented `s3_media_upload update … && upload … --delete` pair to hand the local copies back. Steady state on disk: media from roughly the last 30 minutes plus the link-preview cache, i.e. a few MB instead of the whole store.
  * **URL previews stay on disk by design**: this is Synapse itself, not the plugin — `MediaStorage.fetch_media()` short-circuits `file_info.url_cache` ("URL cache files are stored locally and should not go through storage providers"), so preview cards can never be read from or written to Garage. `url_preview_enabled` is at its default (`true`), and `s3_media_upload` skips those rows (`url_cache IS NULL`), so previews are neither uploaded nor deleted.
  * **Race-free offload**: the timer asks for media whose *last access* is older than `1800s`, far beyond the lifetime of an upload or download in flight, so a file is never deleted out from under a running request. The one-time migration passes `1s` (= the whole store) and runs before Synapse starts, when nothing can be in flight.
  * **Duration gotcha — use `s`, never `m`**: `s3_media_upload` accepts `s`/`h`/`d`/`m`/`y` where **`m` means 30-day months** and there is no minute unit (the script comments that "seconds can be used to implement minutes"). Passing `30m` therefore means 900 days and the job silently offloads nothing — it exits `0` and reports `Syncing files that haven't been accessed since: <two and a half years ago>`. That was caught live on 2026-10-31 by reading the unit's journal output, not the exit code; check that line whenever the numbers look suspiciously empty. (The unrelated `OnUnitActiveSec = "30m"` in the timer is a systemd duration, where `m` *is* minutes.)
  * **Activation is file-driven, so no credential is ever committed**: the block is written only when *both* `/var/lib/secrets/matrix/s3/access-key` (Garage **key id**, `GK…`) and `/var/lib/secrets/matrix/s3/secret-key` exist and are non-empty; otherwise Synapse keeps the plain on-disk media store and both sync jobs exit `0` immediately, which is why evaluation and the `vm-nixmatrix` test need no Garage. Note that on CT 109 `/var/lib/secrets/matrix` is a directory **inside the container's own filesystem**, not any kind of network mount at all (the only bind entries on CT 109 are `oauth2/matrix`, `postgres/matrix` and `coturn`, and all three come from the host's own disk), so the key files are created inside the container:
    ```bash
    pct exec 109 -- /run/current-system/sw/bin/bash -c '
      install -d -m 700 -o root -g root /var/lib/secrets/matrix/s3
      printf %s "<Garage key id>"     > /var/lib/secrets/matrix/s3/access-key
      printf %s "<Garage secret key>" > /var/lib/secrets/matrix/s3/secret-key
      chmod 600 /var/lib/secrets/matrix/s3/access-key /var/lib/secrets/matrix/s3/secret-key'
    ```
    Both files are root-only (`0600`), consistent with every other secret in this repo: the root-run `matrix-synapse-secrets-config` unit reads them and hands the unprivileged sync units a `0600 matrix-synapse` env file (`/var/lib/matrix-synapse/s3-migration/credentials.env`).
  * **One-time migration of existing media**: `matrix-synapse-s3-media-migration` runs *before* `matrix-synapse.service` (so no upload can slip through while copying) and is pulled in via `Wants=`. It drops `/var/lib/matrix-synapse/.s3-media-migrated` so it never repeats. URL-preview files are never touched (they must stay on disk). First run on 2026-10-30: 707 media / 737 files / 302 MB in ~5 min, with the object keys and MD5s verified against a pre-migration backup. Snapshot the container first (`pct snapshot 109 pre-s3-media-<date>`) and expect the switch to block while Synapse is stopped for the duration of the upload.
  * **Recurring offload**: `matrix-synapse-s3-media-cleanup.timer` fires 15 min after boot and then every 30 min (`OnBootSec`/`OnUnitActiveSec`). It is a plain timer unit — *not* `Wanted=`/`PartOf=` `matrix-synapse.service`, because the config service it depends on is bound to Synapse with `BindsTo=`/`PartOf=` and would otherwise be able to stop Synapse. Both jobs share one script (`s3MediaSync` in `nixmatrix/synapse.nix`) and one incremental sqlite cache (`/var/lib/matrix-synapse/s3-migration/cache.db`), so a normal run is a database scan plus a few `HEAD` requests and uploads nothing.
  * **Safe by construction**: the migration is `Wanted` but not `Required`/`PartOf`, so a failed upload (Garage down, bad key) never keeps Synapse from starting — it retries on the next start until the marker exists; without key files both units exit `0` immediately. Since uploads are mirrored synchronously, a missed cleanup run only delays reclaiming disk space, it never loses media.
  * **Verify**: `systemctl list-timers 'matrix-synapse-s3-media-*'`, `systemctl status matrix-synapse-s3-media-cleanup`, `journalctl -u matrix-synapse | grep -i storage` (no provider errors), `grep -A8 media_storage_providers /var/lib/matrix-synapse/secrets.yaml`, `du -sh /var/lib/matrix-synapse/media_store` (stays small), and in Element: upload a photo, open an old attachment, paste a link (preview card). From any LAN machine holding the same key: `aws --endpoint-url http://192.168.1.132:3900 s3 ls s3://synapse --recursive --summarize`.
  * **Rollback** (all three are available): delete the marker + `s3/` key files and rebuild to drop back to the on-disk store (objects already in Garage stay there and keep being served while the provider block is generated); or `nixos-rebuild switch --generation <pre-S3 gen>` inside the container; or `pct rollback 109 <snapshot>` (needs a container stop/start). A media-store tar backup is kept at `/mnt/pve/nas/shared/media-backups/nixmatrix-media_store-<date>.tar.gz` in case local copies must be restored without rolling the whole container back.
  * **Trade-offs**: media availability now follows Garage — if the bucket is unreachable, uploads and attachments fail (LAN-only path; the WireGuard edge is not involved). Media that has already been offloaded is served from Garage, so a Garage outage also affects old attachments until it is reachable again.

  * **All media is authenticated (MSC3916) — the storage backend is usually *not* the culprit when images fail**: `enable_authenticated_media` is at its default (`true`) in Synapse 1.163 and every row in `local_media_repository` has `authenticated = true`. The legacy endpoints `/_matrix/media/v3/{download,thumbnail}/…` call `get_local_media(..., allow_authenticated = False)` and therefore raise `NotFoundError` (`media_repository.py`: `if enable_authenticated_media and not allow_authenticated: if media_info.authenticated: raise NotFoundError()`), i.e. **404 in ~3 ms with a single DB query and no S3 access at all**. Clients must use `/_matrix/client/v1/media/…` with a bearer token; `/_matrix/client/versions` advertises `v1.11` for exactly this reason, and Element Web renders `<img>` tags through its service worker (`/sw.js`, which adds the token and rewrites to `client/v1`) because an `<img>` cannot send headers itself. Two consequences worth remembering: a browser session whose service worker is not registered/controlling falls back to the legacy token-less URLs and shows „Fehler beim Herunterladen des Bildes“ even though the bytes are fine (fix: reload twice, or clear site data for `matrix.minnecker.com` and log in again); and `/_matrix/media/v3/preview_url` moved to `/_matrix/client/v1/media/preview_url`. Do **not** "fix" this with `enable_authenticated_media: false` — that is a privacy regression and is being removed upstream.
  * **Split rate-limit buckets on `nixnginx`**: because the service worker fetches dozens of `client/v1/media` objects in parallel for one room, Matrix media gets its own `limit_req`/`limit_conn` bucket instead of the global one; see "Rate limiting" in `nixnginx/README.md`. Sharing the global bucket (30 r/s, 40 connections counted across *all* vhosts on this IP for one client) produced `429`/`503` on exactly those requests on 2026-10-31.
  * **Verify media end to end without a browser**: the object key is `local_content/<media_id[0:2]>/<media_id[2:4]>/<filesystem_id>` — note the last component is the **filesystem id, not the `media_id`** (Synapse ≥ 1.163 prefixes the media id with a 4-character shard, so `media_id = "iZxM…"` lives at `…/iZ/xM/mQRa…`). `local_media_repository.sha256` stores the hex digest of the content, so `sha256sum` of a `GetObject` body versus that column proves the migrated bytes bit-for-bit; both of the 2026-10-31 uploads matched (`0ca8db091fdf5708…`, `f1f1895fc60e8732…`). Encrypted (Element X) uploads legitimately show `media_type = application/octet-stream` and non-JPEG magic bytes.

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
* **INWX API Credentials** (for automatic DNSSEC DS record push):
  Write `/var/lib/secrets/nsd/inwx.env` (chmod 600):
  ```env
  INWX_USER=your_username
  INWX_PASS=your_password
  ```
* **DNSSEC key rotation** is handled by the `nsd-dnssec` service triggered by a systemd timer.
  When keys are rotated and zones are re-signed, the new DS records are automatically pushed
  to INWX via `scratch/push-dnssec-to-inwx.sh`. Run manually at any time:
  ```bash
  /root/nixos-config/scratch/push-dnssec-to-inwx.sh
  ```
  To retrieve DNSKEY and DS records for all zones:
  ```bash
  /root/nixos-config/scratch/get-dnssec-records.sh
  ```

#### 🚀 nixforgejo-runner (Forgejo Actions Runner)
* **Registration Token**: Write `/var/lib/secrets/forgejo/runner-token` (chmod 600):
  ```env
  TOKEN="your_registration_token"
  ```

#### 🕸️ nixnginx (Nginx Reverse Proxy)
* Refer to the specific [nixnginx/README.md](file:///root/nixos-config/nixnginx/README.md) for detailed credentials and configuration specifications for SSL certificates, Nextcloud database credentials, and Roundcube secrets.

#### ☁️ Nextcloud user files on Garage S3 (primary storage)

Since 2026-11-01 the **content** of every Nextcloud user file lives in the Garage
bucket `nextcloud` on `192.168.1.132:3900` (path-style, plain HTTP, region
`garage`).  This is *primary* storage, not a mirror: unlike the Matrix media
setup (where `store_local` must stay on, see the nixmatrix section), Nextcloud
writes and reads user files through the object store only.  Warm copy ran
2026-10-31 (35 740 objects / 238.3 GB), the cut-over landed 2026-11-01 08:35 and
the NAS datadir mount was dropped at 08:47 the same morning.

**Object keys.** `urn:oid:<oc_filecache.fileid>` — `ObjectStoreStorage::getURN()`
returns `objectPrefix . $fileId` and the default prefix is `urn:oid:`.  Each
revision is a separate `oc_filecache` row with its own `fileid`, including
`files_versions` entries, so an object is never rewritten in place and a copy
tool only ever adds keys.

**Storage ids.** Enabling the object store changes which storage id Nextcloud
resolves for a home: `OC\Files\Mount\ObjectHomeMountProvider` (storage id
`object::user:<uid>`, one `oc_storages` row **per user**, from
`HomeObjectStoreStorage::getId()`) replaces `LocalHomeMountProvider`
(`home::<uid>`).  Three tables carry a storage id — `oc_filecache.storage`,
`oc_mounts.storage_id`, `oc_previews.storage_id`; NC 33 has no
`oc_home_to_storage`.  `nixnginx/maintenance/remap-objectstore.sql` moves all
three in one guarded transaction (it aborts unless all six users map, and the
join on `oc_storages.id` refuses to remap rows if a numeric id drifted).  Share
mounts follow the *owner's* storage, which the same `storage_id` update handles.

**Configuration** lives in `nixnginx/nginx.nix` under
`services.nextcloud.config.objectstore.s3`.  The bucket, access key id, endpoint
and region are non-secret; the secret key is read at service start through
`LoadCredential=s3_secret` (the module's `runtimeSystemdCredentials`, which reach
the phpfpm pool, cron, setup units and the `occ` wrapper) from
`nixnginx:/var/lib/secrets/s3/nextcloud/secret-key`, `root:root` mode 600 on the
container's own disk — so nothing secret lands in the Nix store and the file is
not readable by the `nextcloud` php-fpm user directly.

**Cut-over order** (all steps in one maintenance window, because enabling the
object store before the rows are remapped would make existing files temporarily
invisible):

```bash
# on the Proxmox host; copy nixnginx/maintenance/*.sh to px:/tmp first
cp nixnginx/maintenance/*.sh /tmp/ && chmod +x /tmp/cutover-*.sh
/tmp/cutover-a.sh          # pg_dump -> maintenance:mode --on -> fresh manifest +
                           # delta/repair copy -> bucket reconcile gate -> remap
/tmp/cutover-b.sh          # nixos-rebuild switch -> assert objectstore is live
                           # -> maintenance:mode --off -> read test -> occ status
```

Part A is written to fail *before* the database write: if the delta pass cannot
verify an object, or the reconcile gate reports `missing` / `size_mismatch`, it
runs `maintenance:mode --off` and exits without touching Postgres.  Part B keeps
maintenance mode on if the rebuild did not take effect, because the rows are
already remapped by then and reopening would show users an empty Files app.

**The manifest must be regenerated under maintenance mode.**  A changed file
keeps its `fileid` (only `size`/`etag`/`mtime` move), so a delta pass driven by
the old warm-copy manifest would neither notice a modified file nor a file
uploaded after the manifest was taken.  `nc-s3-delta.sh` re-reads
`oc_filecache`, diffs it against the warm manifest, force-copies new,
size-changed and previously-failed fileids, then promotes the fresh manifest so
the reconcile gate compares against reality.

**Three tooling bugs this surfaced, all fixed in the tools:**

* `fwrite($out, "$o->Size")` on an `Aws\Result` interpolates to the empty
  string — array access (`$o['Size']`) is required.  Every bucket object size
  landed as 0 and the reconcile gate aborted on 35672 phantom `size_mismatch`
  rows.  The abort was correct behaviour: the gate ran *before* any database
  write and reopened the site untouched.
* **Garage does not use the S3 multipart ETag formula.**  S3 returns
  `md5(raw part digests)-N`; Garage returns `md5(HEX part digests)-N`.  Measured
  directly with a controlled 3-part upload of random data:
  `standard md5(raw)=bf36ff1a…-3`, `md5(hex)=a1976dcd…-3`, and Garage answered
  `a1976dcd…-3`.  The copy tool assumed the S3 formula, so the single file above
  the 2 GiB multipart threshold (a 7.4 GB `.mov`) was reported as a corrupt
  upload.  It was not corrupt: ranged `GET`s of its first and last part matched
  the original byte-for-byte, and `multipartEtags()` now accepts both formulas.
  Worth remembering: **only files > 2 GiB go through `MultipartUploader`**, so
  an ETag-formula bug is invisible on the other 35 739 objects, which are
  verified as a plain whole-body MD5.  Parts are additionally hashed from
  explicit seek offsets and read until full, because `fread()` may short-read on
  NFS while `MultipartUploader` loops until a part is full — a silent way to get
  an ETag with the right part count and the wrong digest.
* The idempotency fast-path accepted an existing object on a **size-only**
  `HEAD` match, so a file whose object was wrong got marked done and would never
  be repaired.  `HEAD` now has to match the ETag too, and `nc-s3-delta.sh`
  purges previously-failed fileids from the `done-w*.txt` ledgers, because those
  entries were written under the size-only rule.

**Rollback paths** (all of these are still in place on the Proxmox host):

| Artifact | Restores |
| --- | --- |
| `/tmp/cutover-rollback.sh CONFIRM` | database + Nix config in one go |
| `/var/lib/nc-backups/nextcloud-pre-remap.dump` | the database as of the remap (4.9 MB) |
| `/var/lib/nc-backups/{nextcloud-pre-s3.dump,nextcloud-pre-s3.sql,config.php.pre-s3,104.conf.pre-s3}` | the pre-migration database, config and container mount list |
| `/root/backups/nextcloud-off-nas-*/104.conf.pre-off-nas` | the NAS datadir mount line (then `pct stop 104 && pct start 104`) |
| LXC snapshots `pre-s3-nextcloud-20261031`, `pre-off-nas-20261101` | the whole container (needs a stop/start) |
| `/mnt/pve/nas/shared/nextcloud/data_new` | every user file, byte for byte — the tree was only ever read |

**What stays on the datadir, and where the datadir now lives:** `config/`
(3.4 KB), `appdata_oc5veetcuvee/` (previews, avatars, DAV), the `.ncdata` marker
and per-user scratch dirs — 173 MB in total, which is why the datadir itself does
not move into the bucket.  Since part C it lives on `nixnginx`'s own ZFS volume
and is **not** an NFS bind mount any more; `/mnt/pve/nas/shared/nextcloud/data_new`
is still there, untouched, as the rollback path.  User payloads: 35 740 files,
238 GB (florian 108.8 GB, sabine 111.5 GB, helena 18.1 GB).

**Part C — dropping the NAS datadir mount** (`nixnginx/maintenance/move-datadir-off-nas.sh`,
run on the Proxmox host).  It is worth reading before you touch any LXC mount by
hand, because the first attempt at this produced a container that booted with an
empty datadir:

* `nixnginx`'s rootfs is the ZFS dataset `fast/subvol-104-disk-0`, which
  Proxmox mounts at **`/fast/subvol-104-disk-0`**, not at
  `/var/lib/lxc/104/rootfs`.  Writing to the latter writes to the host's ext4
  root and the container never sees it.  Find the real path with
  `pct config <ct> | grep rootfs` plus `zfs list -o name,mountpoint,mounted`.
* Seed the new datadir **while the container is running**.  Inside the container
  the target path is covered by the NFS bind mount, so the seed stays invisible
  until the mount is gone — which means the datadir is fully populated *before*
  the container ever boots without the mount.  Seeding while stopped instead
  boots Nextcloud with no `config.php`, and `nextcloud-setup-oidc` then asks
  `Do you want to run "maintenance:install" instead?` — an interactive `no` saved
  this installation.  Treat that prompt as the sharp edge it is.
* Guard the copy with a size comparison: the container's `config.php` (NFS) and
  the host-side one must differ in size, otherwise you are about to overwrite
  the live file.  `nextcloud` is uid **995** / gid **994** inside, i.e. 100995 /
  100994 on the host.

Post-cutover verification that was actually run: `occ status` reports
`installed: true`; `objectstore class = \OC\Files\ObjectStore\S3`; 12 sampled
files per read test read back through Nextcloud with MD5s equal to the bucket
objects; a fresh 512 KB upload appears as `urn:oid:<new fileid>` with a matching
MD5 and **no** local copy; `cloud.minnecker.com` → 302,
`matrix.minnecker.com/_matrix/client/versions` → 200.

**Two traps worth remembering:**

* `SELECT sum(size) FROM oc_filecache` counts *directory* rows too, and those
  carry the size of their whole subtree — that read 1.4 TB for a 238 GB tree.
  Filter with `mimetype <> 2` (`httpd/unix-directory`).
* Garage runs with `replica = 1`, so these objects are single-copy: one dead
  disk loses them.  Consider `replica = 2` before the NAS copy is deleted.

**Migration tooling** — kept under `nixnginx/maintenance/` for reproducibility,
state lives in `nixnginx:/var/lib/nc-s3-migration/` and is deleted afterwards:

| File | Purpose |
| --- | --- |
| `nc-s3-copy.php` | Warm/delta copy.  Streams each file through a custom `teehash://` wrapper that MD5s exactly the bytes that were sent, multipart above 2 GiB, verifies `HEAD` length *and* ETag, resumable through the `done-w*.txt` ledgers, `--force` to repair a known-bad object.  Eight workers reached ~50 MB/s over the NFS → Garage path. |
| `nc-s3-inventory.php` | `dump` lists the bucket into `inventory.tsv`, `check` reconciles it against `manifest.tsv` (missing / size-mismatch / extra).  Read-only. |
| `nc-s3-delta.sh` | Maintenance-mode step: fresh manifest from `oc_filecache`, ledger repair, force-copy delta, hard-fail on any unverifiable object. |
| `nc-s3-readtest.php` | Reads sampled files back *through Nextcloud* and compares the MD5 against the original — the datadir copy while it existed, the bucket object since part C.  Prints the storage id, so `object::user:<uid>` proves the object store is really in use. |
| `nc-s3-writetest.php` | Writes a file as a real user and proves the new bytes land in the bucket as `urn:oid:<fileid>` with **no** local copy.  Run it after any storage change; needs `NC_CODE` (resolve with `grep -o '/nix/store/.*nextcloud-[0-9.]*-with-apps' "$(readlink -f "$(command -v nextcloud-occ)")" | head -1`) and the `LoadCredential=dbpass,secret_file,s3_secret` unit properties, see `nc-s3-readtest.sh` for the pattern. |
| `remap-objectstore.sql` | The storage-id transaction (guarded; aborts unless every user maps). |
| `cutover-a.sh` / `cutover-b.sh` / `cutover-rollback.sh` | Host-side runbook: gated cut-over in two halves, and a `CONFIRM`-gated rollback. |
| `move-datadir-off-nas.sh` | Part C: drop the NFS bind mount now that user payloads are in the bucket. |

`manifest.tsv` is 35,740 rows straight from `oc_filecache` (largest file first),
and the `PHP` variable at the top of the shell scripts pins the Nix store path of
Nextcloud 33.0.10's bundled PHP/AWS SDK, which changes on every upgrade.

---

## 🌐 4. Exposing Services & Host Port Routing (NAT)

To allow external access to your containers on Proxmox, you must forward the public ports of the Proxmox host to the respective container IPs.

> **⚠️ The live rules are NOT produced by the script below.** On this host the
> authoritative NAT rules live in `/etc/network/interfaces` on the Proxmox host
> (`post-up`/`post-down` `iptables`/`ip6tables` lines on `enp35s0`, `vmbr0` and
> `vmbr1`). `scratch/setup-host-routing.sh` is a legacy template that still
> assumes the old `172.16.16.0/24` addressing and `enp6s0`; running its
> `enable` action on this host would add stale, wrong rules. Inspect the live
> ruleset instead:
>
> ```bash
> iptables-save  -t nat | grep PREROUTING    # IPv4 port forwards
> ip6tables-save -t nat | grep PREROUTING    # IPv6 port forwards
> grep -n 'ip6tables\|ip addr add' /etc/network/interfaces
> ```

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

---

## 🛡️ 5. IPv6, CrowdSec And "The Site Is Down"

### IPv6 topology

The server has two IPv6 /64 networks on `enp35s0`:

| Address | Role |
| --- | --- |
| `2a01:4f8:13b:a41::2/64` | Hetzner **primary** IPv6 (assigned with the server) |
| `2a01:4f8:fff2:7d::1/64` | Hetzner **floating** IPv6 — this is what `*.minnecker.com` AAAA records point at |

Both are added in `/etc/network/interfaces` (the floating one with an explicit
`ip addr add … dev enp35s0`), and each public port is DNAT-ed to the service
bridge `vmbr1` (`fd01::/64`), exactly like the IPv4 rules:

```text
ip6tables -t nat -A PREROUTING -d 2a01:4f8:fff2:7d::1 -p tcp -m multiport \
          --dports 80,443 -j DNAT --to fd01::14      # nixnginx
```

Reply traffic is un-NAT-ed by conntrack and additionally SNAT-ed to the
floating address, so a container's own outbound IPv6 also appears as
`2a01:4f8:fff2:7d::1`.

Verify from a host with working IPv6 (note the `-g` and the bracketed
`--resolve` value — zsh globs bare `[...]`):

```bash
curl -6 -g -o /dev/null -w '%{http_code} %{remote_ip}\n' https://cloud.minnecker.com/
curl -6 -g -o /dev/null -w '%{http_code} %{remote_ip}\n' https://matrix.minnecker.com/_matrix/client/versions
```

Expected: `302` / `200` with `remote_ip = 2a01:4f8:fff2:7d::1`.

### CrowdSec and why the operator gets locked out

CrowdSec runs on **nixnginx (CT 104)**: the agent parses nginx access logs from
journald, the LAPI is served on `10.20.20.14:8080`, and
`crowdsec-firewall-bouncer` turns decisions into ipset DROP rules
(`crowdsec-blacklists-0` for v4, `crowdsec6-blacklists-0` for v6) in the
container's `INPUT` chain. nixmail runs an agent only. See
`nixnginx/configuration.nix`.

Because the bouncer sits in front of **every** vhost on that box, one decision
takes down cloud, matrix, git, idm, wiki and vaultwarden at once.

The nasty part is that the operator lives behind the same NAT as everybody else
in the household, and the egress address is **dynamic** (dynamic IPv4, and the
ISP renumbers the IPv6 prefix). An IP allowlist would therefore rot silently and
give false confidence, so there isn't one. Instead the false positives are
removed structurally, in three places:

1. **nginx (`nixnginx/nginx.nix`) — the actual trigger.** The shared edge limit
   was `rate=30r/s burst=60` per source address. Several Nextcloud sync clients
   plus DAV polling plus browsing from one household address exceed that in
   bursts; nginx then logs `limiting requests`, and the
   `crowdsecurity/nginx-req-limit-exceeded` scenario turns that into a 4 h
   firewall ban. Raised to `50r/s`/`burst=150`/`limit_conn addr 80`. This is the
   fix; the CrowdSec knobs below only soften what is left.
2. **A relaxed replacement for `http-probing`.** The hub scenario bans on 10
   distinct 404/403/400 paths within 10 s, and its `blackhole: 5m` re-bans
   instantly on any further hit — reachable by any CLI that retries a few
   missing files. Hub scenarios cannot be edited in place (cscli re-creates the
   symlinks at every start), so `services.crowdsec.localConfig.scenarios`
   provides `local/http-probing-relaxed` with `capacity: 25` and no blackhole.
3. **`scenarios_not_containing` on the bouncer** for
   `crowdsecurity/http-probing` and `crowdsecurity/nginx-req-limit-exceeded`.
   Both measure "this client was already throttled", so they double-punish;
   filtering them keeps the alerts (still visible in `cscli alerts list` and
   Grafana) and drops only the ban. Everything else — sensitive files, path
   traversal, CVE probing, brute force, bad user agents — bans at hub defaults.

Only the two static Proxmox host addresses stay allowlisted
(`environment.etc."crowdsec/parsers/s02-enrich/99-local-whitelist-hosts.yaml"`),
because every DNAT/hairpin connection to a container arrives from one of them.

Ban length is **4 h for everything**: this host installs no remediation profile,
so the LAPI default applies and a scenario-level `duration` is silently ignored.
To shorten it, add `services.crowdsec.localConfig.profiles`.

Three upstream footguns make this config easy to get wrong. All three bit during
the first attempts, and each fails **silently** — the generated file looks right
while the running agent behaves differently:

1. **`nixos-rebuild switch` does not restart `crowdsec.service`.** The unit has
   no restart trigger covering the generated config, so the switch rewrites
   `/etc/crowdsec` while the running agent keeps the old ruleset. Explicit
   `restartTriggers` are set now (settings, `localConfig`, hub list, stage file,
   prune script). Verify with
   `systemctl show crowdsec.service -p ActiveEnterTimestamp` — it must be newer
   than the switch. A *unit-file-only* change is merely `daemon-reload`ed, which
   is why the hook itself is a trigger too.
2. **Never put stage files in `services.crowdsec.localConfig.parsers`.** The
   module installs them as tmpfiles.d `L+` entries named
   `<derivation-hash>-parsers-s02-enrich.yaml`, and tmpfiles never prunes them.
   After an edit, two files declare the same `name:` and CrowdSec drops one
   arbitrarily:

   ```text
   level=warning msg="multiple parsers named local/whitelist-hosts:
                      ignoring /etc/crowdsec/parsers/s02-enrich/dzyjixpr….yaml"
   ```

   The new file may lose, silently restoring the previous rules. Keep stage
   files at a fixed `environment.etc` path (replaced in place), which is what
   this config does, and let `crowdsec-stage-prune.service` drop any
   store-pointing orphan that the active tmpfiles rules no longer declare. It is
   pulled in via `wants` + `before`, so it runs on every CrowdSec start, and
   `Wants` (not `Requires`) keeps a pruning failure from taking the agent down.
3. **`systemd.services.crowdsec.preStart` is silently discarded.** The module's
   `extraConfig` contains an empty `ExecStartPre=`, and systemd treats that as
   "reset the list", throwing away anything contributed earlier. Use a separate
   ordered unit instead. CrowdSec's units also run with an **empty `PATH`**, so
   give any helper an explicit `path = [ … ]`; and avoid `find … | while` under
   `set -e`, because a failing `find` in a pipeline still exits 0.

Checking that a filter really works is worth doing properly: the ipset is keyed
by address, so "two decisions produced one ipset entry" proves nothing. The A/B
that settled it was to add the *replacement* scenario to
`scenarios_not_containing` and re-fire the same burst — same detector, same
`ban` decision in the LAPI, and the address stopped entering
`crowdsec6-blacklists-0`. Use `ipset test <set> <addr>`, not `ipset list | grep`.

### "Is it down, or am I banned?"

Check before touching anything else:

```bash
pct exec 104 -- cscli decisions list | grep -E '141\.78|2a02:2761'
# what the kernel is actually blocking (ipset test, not `ipset list | grep`):
pct exec 104 -- ipset test crowdsec-blacklists-0 <your-ipv4>
pct exec 104 -- ipset test crowdsec6-blacklists-0 <your-ipv6>
# unban your own addresses (safe, reversible — a repeat offender just gets
# re-banned):
pct exec 104 -- cscli decisions delete -i 141.78.136.224
pct exec 104 -- cscli decisions delete -i 2a02:2761:1000::1:2cd8
```

### Diagnosing an unreachable public port

The order matters; each step rules out one layer. Run the capture while you
probe from the outside:

```bash
# 1. Does the packet arrive, and is it DNAT-ed towards the container?
tcpdump -ni any -nn 'tcp port 443 and (host <public-v6> or host fd01::14)'
#    enp35s0 In  <client> -> <public-ip>:443   [S]     → routing/DNS is fine
#    vmbr1 Out   <client> -> fd01::14:443       [S]     → DNAT works
#    veth104i0 Out …                            [S]     → host side is done

# 2. Does the container answer?
pct exec 104 -- tcpdump -ni eth0 -nn 'tcp port 443 and host <client>'
```

If the SYNs reach the container and **neither a SYN-ACK nor an RST comes back**
while nginx is listening on `[::]:443`, the packet is being dropped by an
`ipset` DROP rule — i.e. a CrowdSec ban (see the CROWDSEC_CHAIN packet counters
in `ip6tables -L CROWDSEC_CHAIN -n -v -x`). A missing DNAT rule instead shows up
as the packet never leaving `enp35s0`, and a dead route as an RST.

> **Case study — 2026-11-01.** `cloud.minnecker.com` looked down over IPv4 and
> the floating IPv6 "did not work". Both were CrowdSec bans of the household's
> own addresses (`http-probing` on the v6 /128, `nginx-req-limit-exceeded` on
> the v4). The IPv6 floating IP, its DNAT rules and the reply path were all
> correct from the start; the counters in `CROWDSEC_CHAIN` were the smoking gun.
> Cleared with `cscli decisions delete`, all vhosts answer over IPv6 again.
> Nothing is allowlisted afterwards: the nginx limit that produced the ban was
> loosened and the two throttle-shaped scenarios no longer ban, so the same
> ordinary traffic cannot lock the household out again even when the ISP hands
> out new addresses.
