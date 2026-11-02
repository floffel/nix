# niximmich — Immich photo library (CT 116)

Photo and video backup for the phones, replacing the Docker Compose stack that
ran on saver CT 111.

* URL: <https://immich.minnecker.com> (wildcard cert, proxied by `nixnginx`)
* Container: `niximmich`, CT **116**, `10.20.20.26` / `fd01::26`, rootfs
  `fast:40G`, 2 cores / 4 GB
* App: `services.immich` — units `immich-server` (port 2283) and
  `immich-machine-learning` (port 3003)
* Database: **PostgreSQL inside this container** (see below), plus a
  module-managed redis on a private unix socket
* Files: `/var/lib/immich` on the container's own ZFS volume, covered by the
  nightly restic pass through `vzdump 116`

## Status

Container created and the configuration committed, but the service is **not
activated yet** — see [Blockers](#blockers). The first `nixos-rebuild switch`
currently stops at the immich package being marked insecure in nixpkgs
26.05.

## Why PostgreSQL is local here

Every other stateful service in this repository uses `nixpostgresql`. Immich
is the exception, and deliberately: it needs

```
shared_preload_libraries = [ "vchord.so" ]
search_path = "\"$user\", public, vectors"
```

and `pgvector` + `vectorchord` in its database. `shared_preload_libraries` and
`search_path` are **server-wide** settings — putting them on the shared cluster
would change Postgres for Forgejo, Matrix, Nextcloud, Vaultwarden, Wiki.js and
Paperless too, and VectorChord preloading into a server it was never meant to
serve is not a risk worth running on shared infrastructure. So the upstream
module owns this database: it creates role `immich`, database `immich`, and
runs the extension setup as `postgresql-setup`'s `ExecStartPost`.

Consequence: the DB is reached over `/run/postgresql` with peer authentication,
so **there is no database password anywhere** — no secret mount, no
`secretsFile`, nothing to rotate. The only credential in this service is the
admin login and API key, which live in the database and are therefore backed up
with it.

`mediaLocation` is `/var/lib/immich` on the container rootfs. Immich has no
object-storage backend (unlike Synapse and Nextcloud, it cannot put originals
in Garage), so the photos are local files by necessity; that is also why this
container needs a 40 GB volume instead of the 20 GB the other services get.

## Secrets

| What | Where | Why |
| :--- | :--- | :--- |
| — | — | none on disk: peer auth over the unix socket means no DB password |
| Admin login / API keys | inside the PostgreSQL cluster | container-local, backed up with the volume |

## Create the container

```bash
pct create 116 local:vztmpl/nixos-image-lxc-proxmox-26.05pre-git-x86_64-linux.tar.xz \
  --hostname niximmich --ostype nixos --unprivileged 1 --features nesting=1 \
  --storage fast --rootfs fast:40 --cores 2 --memory 4096 --swap 2048 \
  --onboot 1 --startup order=2 \
  --net0 name=eth0,bridge=vmbr1,gw=10.20.20.1,gw6=fd01::1,ip=10.20.20.26/24,ip6=fd01::26/64
```

No `lxc.mount.entry` lines — there is nothing shared to mount.

Then the usual in-container flow. Note that a **fresh image has neither `git`
nor a populated channel**, so `git clone` is not available yet; bootstrap
through the channel first:

```bash
nix-channel --add https://channels.nixos.org/nixos-26.05 nixos && nix-channel --update
export NIX_PATH=nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix:/nix/var/nix/profiles/per-user/root/channels
nix-shell -p git --run 'git clone https://github.com/floffel/nix.git /root/nixos-config'
ln -sfn /root/nixos-config/niximmich/configuration.nix /etc/nixos/configuration.nix
ln -sfn /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sfn /root/nixos-config/hosts.nix /etc/nixos/hosts.nix
cd /root && nixos-rebuild switch
```

After that `/root/ct-deploy.sh` works as everywhere else.

## Blockers

Two things stand between the committed config and a running service. Neither
is a code problem in this repository.

### 1. The immich package in nixpkgs 26.05 is EOL and flagged insecure

The first rebuild fails with:

```
error: Refusing to evaluate package 'immich-2.7.5' ... because it is marked as insecure
Known issues:
 - Immich 2.x.x will not receive further updates. Immich 3.x.x is available in NixOS 26.11
 - CVE-2026-59258
 - CVE-2026-82272
```

`nix flake check` passes because the flake is locked to an older 26.05 commit
from before the annotation; the container builds against the **channel**, which
is newer and does carry it. That split — flake lock for checks, channel for
deploys — is what made this surface only at deploy time.

Three ways forward:

* **Pin immich 3.x from nixpkgs-unstable** (overlay `immich` plus the
  matching module from the same input). Recommended: it is the only option with
  a supported release, and the module's option set is unchanged, so
  `immich.nix` needs no edits. Needs a second flake input.
* `nixpkgs.config.permittedInsecurePackages = [ "immich-2.7.5" ];` — works
  today, but puts a photo library that is reachable from the internet on an
  EOL release with two unpatched CVEs.
* Wait for 26.11 to carry 3.x on the stable channel.

Whichever is chosen, say so before deploying, and do not let the first
`nixos-rebuild switch` on this container silently pull whatever the channel
happens to hold.

### 2. The library is on the NAS, and the NAS is powered off

The old upload directory is not on saver at all — it is an LXC bind mount of
the retired NAS share:

```
# /etc/pve/lxc/111.conf  (saver)
lxc.mount.entry: /mnt/pve/nas/shared/immichlibrary srv/immichlibrary none bind,rw 0 0
# saver /etc/pve/storage.cfg
nfs: nas   server 192.168.1.203   export /mnt/big/remote
```

As of 2026-11-02 `192.168.1.203` does not answer ARP on the LAN, does not ping
from the laptop, from px or from saver, and `ls` on the mounted path blocks
forever (the mount is `hard`). So the photos are safe but unreachable, and any
`du`/`ls` that touches `/srv/immichlibrary` on saver hangs — which is also why
inspecting the old stack is slow.

**Bring the NAS back on the network before starting the migration.** Nothing
else in the new stack depends on it; immich's database (158 MB) and the ML
model cache are on saver's local disk and are readable today.

There is no copy of the library anywhere else: the Garage bucket listing has
`synapse`, `nextcloud` and `pxbackup` only, and the restic repository holds px
guests, which never included the NAS.

## Migration runbook (once the NAS is up)

Do this in order. Steps 1–3 happen on the old stack, which means they can be
reverted by switching the compose file back.

1. **Back up first.** On saver, start only the database
   (`docker start immich_postgres`) and take `pg_dump -Fc` of the `immich`
   database; copy the dump *and* `/srv/immichlibrary` off saver. Garage is
   reachable from saver (`192.168.1.132:3900` via `172.16.16.11`), so rclone
   to a staging prefix is the fast path; the laptop link is ~3.5 MB/s and would
   take hours.
2. **Do the pgvecto-rs → VectorChord conversion on the old stack, not here.**
   The old database is `tensorchord/pgvecto-rs:pg14-v0.2.0`. pgvecto-rs no
   longer exists in nixpkgs, so its dump **cannot be restored** into the
   Postgres this module builds — the `vectors` extension and the `vectors.vector`
   column type would both fail. Immich migrates the extension itself when the
   server starts against a Postgres that has both, which is exactly what
   `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` is for:
   change that one image in `/root/container/immich/docker-compose.yml`, bring
   the stack up, and let it convert.
3. **Match versions.** Whatever version the old stack ends up on must be the
   version this container runs, because immich will not restore a dump from a
   newer server. Pin the compose `IMMICH_VERSION` to whatever
   `services.immich.package` resolves to before dumping in step 4. Upgrading
   v1.129.0 straight to 2.x/3.x is a supported single step, but do it here,
   where the previous version is still one `docker compose up` away.
4. **Restore here.** Stop `immich-server`, `dropdb`/`createdb` the `immich`
   database (the module recreates the schema and extensions on
   `postgresql-setup` restart), `pg_restore` the dump, move the library into
   `/var/lib/immich`, `chown -R immich:immich`, start the units.
5. **Verify** the web UI shows the expected photo count and that an old
   thumbnail renders, then open the vhost.
6. Only then stop the saver stack for good.

## nginx

`immich.minnecker.com` is defined in `nixnginx` (upstream `niximmich:2283`)
with a 4 GiB `client_max_body_size` for phone video uploads and a websocket
location for `/api/socket.io`. `*` is already a CNAME to `px` in the DNS zone,
so no record is needed. Until this container serves traffic the vhost answers
502, which is harmless — but it means deploying `nixnginx` before immich is
live produces a visible broken subdomain.
