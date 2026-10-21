# Upgrading the NixOS Containers

This guide describes how to upgrade the NixOS channel used by all Proxmox LXC
containers in this repository. It is written from the procedure used for the
26.05.12250 upgrade and includes the pitfalls that actually came up.

> **Secrets:** never put secret values (passwords, tokens, private keys, OAuth
> client secrets, mail master passwords) in this repository or in a log. All
> secrets are provisioned from the shared NAS mount and are referenced by path
> in the Nix configuration. The upgrade procedure below only needs paths and
> service names, never the contents of those files.

## How deployment works

- Each container runs NixOS with the `nixos-26.05` channel.
- `/etc/nixos/configuration.nix` is a symlink to
  `/root/nixos-config/<container>/configuration.nix`; `common-lxc.nix` and
  `hosts.nix` are symlinked next to it.
- The configuration is a plain NixOS module set. The `flake.nix` in this
  repository is used for checks/tests only: there are **no
  `nixosConfigurations`**, so `nixos-rebuild --flake` does not work on the
  targets. Use the classic `/etc/nixos` flow.
- The repository is cloned to `/root/nixos-config` inside each container and
  updated with `git pull --ff-only`.
- Never run a destructive `git` command to resolve local changes. The only
  expected local change is an executable-bit change on helper scripts in
  `scratch/`; check with `git status --porcelain` if a pull refuses.

## 0. Preparation

> **Never stop or reboot `nixwireguard` (CT 100) from a remote session.** It
> is the network edge and the path to the host/NAS storage. Applying LXC
> mount changes by stopping it can deadlock storage and lock you out. Use an
> out-of-band console and run edge restarts detached; see `AGENTS.md`.

Work from the Proxmox host (the `pct` commands below are host commands).

```bash
pct list
```

Confirm:

- SSH access to the Proxmox host works. If the main access path depends on
  the WireGuard container, also confirm a fallback route to the host **before**
  touching that container.
- The containers are on branch `main` and the working tree is clean enough for
  `git pull --ff-only`:

  ```bash
  for id in $(pct list | awk 'NR>1 {print $1}'); do
    echo "=== $id ==="
    pct exec "$id" -- /run/current-system/sw/bin/bash -lc \
      'hostname; nixos-version; git -C /root/nixos-config status --porcelain | head -3'
  done
  ```

- There is enough free space in `/nix` (a few GB per container is enough for a
  channel bump; more for large closures such as Open WebUI/Forgejo):

  ```bash
  for id in $(pct list | awk 'NR>1 {print $1}'); do
    printf '%s ' "$id"
    pct exec "$id" -- /run/current-system/sw/bin/bash -lc 'df -h /nix | tail -1'
  done
  ```

### Snapshots

Take a snapshot of **every** container before switching anything. On ZFS this
is cheap. Snapshot names must not contain dots (`.`) and must be valid
configuration IDs; use letters, digits and hyphens.

```bash
STAMP="preupgrade-$(date +%Y%m%d)"
for id in $(pct list | awk 'NR>1 {print $1}'); do
  pct snapshot "$id" "$STAMP"
done
```

Keep the snapshots until the upgrade has been verified for a few days. See
[Rollback](#4-rollback).

## 1. Build only (no downtime)

**Build every container first, then switch.** A build catches removed packages,
EOL packages and build-time resource problems without restarting services.

For each container:

```bash
cd /root/nixos-config
git pull --ff-only
nix-channel --update
cd /root
nixos-rebuild build
```

`nixos-rebuild build` writes `/root/result`; the later `switch` reuses the
already-built store paths and is fast.

### Run it from the host, detached

A channel update plus builds can take a long time. Run the loop as a transient
host service so an SSH disconnect cannot kill it:

```bash
cat >/root/upgrade-build.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
LOG=/root/upgrade-build.log
: >"$LOG"
# Adjust the list; put nixwireguard (VPN) last.
IDS=(102 108 109 110 111 112 113 114 101 106 107 105 104 103 100)
for id in "${IDS[@]}"; do
  name=$(pct config "$id" | awk '/^hostname:/{print $2}')
  echo "=== $(date -Is) $id $name: update + build ===" | tee -a "$LOG"
  pct exec "$id" -- /run/current-system/sw/bin/bash -lc '
    set -euo pipefail
    cd /root/nixos-config
    git pull --ff-only
    nix-channel --update
    cd /root
    nixos-rebuild build
  ' >>"$LOG" 2>&1
  rc=$?
  echo "=== $id $name build rc=$rc ===" | tee -a "$LOG"
  if [ "$rc" -ne 0 ]; then
    echo "STOPPING: build failed for $id $name" | tee -a "$LOG"
    exit "$rc"
  fi
done
echo "ALL BUILDS OK" | tee -a "$LOG"
EOF
chmod +x /root/upgrade-build.sh
systemd-run --unit=container-upgrade-build --collect /root/upgrade-build.sh
```

Monitor with:

```bash
grep -E '^=== .*build rc=|ALL BUILDS|STOPPING' /root/upgrade-build.log
systemctl is-active container-upgrade-build.service
```

### Build-time pitfalls

- **Open WebUI:** the Svelte frontend build can be OOM-killed in a 4 GB
  container. Raise the container memory temporarily for the build (for
  example to 8 GB) or build the same configuration on a container with more
  RAM, then switch. A killed `npm run build` shows up as `Killed` /
  `builder failed with exit code 1` and not as a code error.
- **Kanidm:** a new channel may mark the pinned Kanidm release as insecure/EOL
  (for example `kanidm 1.10 has reached end-of-life`). Upgrade **one supported
  version at a time**:
  1. Run the pre-upgrade check with the **currently deployed** version:
     ```bash
     pct exec <idm-id> -- /run/current-system/sw/bin/bash -lc \
       'BIN=$(systemctl cat kanidm | sed -n "s/^ExecStart=\([^ ]*\).*/\1/p" | head -1);
        CONF=$(systemctl cat kanidm | sed -n "s/.* -c \([^ ]*\).*/\1/p" | head -1);
        runuser -u kanidm -- "$BIN" domain upgrade-check -c "$CONF"'
     ```
     All items must report `PASS`.
  2. Update both the server package and the CLI package in the Nix config
     (for example `pkgs.kanidm_1_11.withSecretProvisioning` and
     `environment.systemPackages`).
  3. Rebuild and switch. The server upgrades the domain on startup in one
     transaction. Downgrades are not supported; keep the snapshot.
- **PostgreSQL:** keep the major version pinned in
  `nixpostgres/postgresql.nix` (currently `pkgs.postgresql_17`). Do not let a
  channel update silently change the default major version; that requires a
  planned `pg_upgrade`.
- **Postfix master.cf:** the NixOS module's `settings.master.smtp` entry is the
  outbound `smtp unix` transport. Do **not** override it to add a port-25
  listener. Port 25 is the separate `smtp_inet` entry; switch only its
  `command` to `postscreen`. If outbound mail stops with
  `mail transport unavailable` (`dsn=4.3.0`), check that
  `postconf -M | grep '^smtp'` shows **both** `smtp unix ... smtp` and
  `smtp inet ... postscreen`.
- **Roundcube markasjunk:** the `nixnginx` package override patches
  `plugins/markasjunk/markasjunk{,.min}.js` so the Spam button passes the
  server-returned UIDs to `move_messages()`. Grep checks in the derivation
  fail the build if a Roundcube/nixpkgs update changes the patch target, so
  the fix cannot silently disappear. Re-check the sed expression after a
  Roundcube upgrade (and remove it if upstream fixes the bug).
- **Open WebUI 0.12.2+:** `/api/v1/auths/` requires a **human session** and
  rejects API keys. When testing the mail tool, use a real logged-in session,
  not an API key. The tool server itself uses `auth_type: "session"`, so this
  is expected to keep working.

## 2. Switch

Only switch containers whose build succeeded. Do not use
`nixos-rebuild switch --upgrade` at this point; the channel was already
updated during the build phase.

Suggested order (dependencies first, VPN last):

1. DNS: `nixnsd`, `nixunbound`
2. Database: `nixpostgresql`
3. Identity: `nixidm`
4. Applications: `nixforgejo`, `nixmatrix`, `nixvaultwarden`, `nixwikijs`,
   `nixjitsi`, `nixmonitoring`, `nixforgejo-runner`, `nixopenwebui`
5. Reverse proxy: `nixnginx`
6. Mail: `nixmail`
7. VPN: `nixwireguard` (last, detached; see below)

For each container:

```bash
timeout 1800 pct exec "$id" -- /run/current-system/sw/bin/bash -lc \
  'cd /root && nixos-rebuild switch'
pct exec "$id" -- /run/current-system/sw/bin/bash -lc \
  'nixos-version; systemctl --failed --no-legend; systemctl is-system-running | head -1'
```

Notes:

- `switch-to-configuration` can sit in uninterruptible sleep (`D` state) for
  several minutes on a busy ZFS pool after large builds. Do not kill it
  immediately; check `journalctl -u nixos-rebuild-switch-to-configuration`
  and wait. A completed switch logs `finished switching to system
  configuration`.
- Use a host-side `timeout` (for example 30 minutes) and log the output. If the
  timeout fires, inspect the container before retrying; the switch may still
  have continued.
- `pct exec` does not inherit the NixOS `PATH` for bare commands. Use
  `bash -lc` or absolute paths such as
  `/run/current-system/sw/bin/systemctl`.
- For a transient `systemd-run` unit that calls `nixos-rebuild` directly, use
  an absolute shebang (`#!/run/current-system/sw/bin/bash`) and set
  `NIX_PATH=nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix`.

### WireGuard last

Switching `nixwireguard` can drop the tunnel used to reach the host. Run that
switch from a transient host service (so it survives the disconnect) and use a
fallback access route to read the result:

```bash
cat >/root/upgrade-wireguard.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
LOG=/root/upgrade-wireguard.log
: >"$LOG"
pct exec <vpn-id> -- /run/current-system/sw/bin/bash -lc \
  'cd /root && nixos-rebuild switch' >>"$LOG" 2>&1
pct exec <vpn-id> -- /run/current-system/sw/bin/bash -lc \
  'nixos-version; systemctl --failed --no-legend; systemctl is-system-running | head -1' \
  >>"$LOG" 2>&1
echo DONE >>"$LOG"
EOF
chmod +x /root/upgrade-wireguard.sh
systemd-run --unit=container-upgrade-wireguard --collect /root/upgrade-wireguard.sh
```

Afterwards, reconnect and verify `wg show` and normal SSH access before
removing the snapshots.

## 3. Verification

### All containers

```bash
for id in $(pct list | awk 'NR>1 {print $1}'); do
  printf '%s: ' "$id"
  pct exec "$id" -- /run/current-system/sw/bin/bash -lc \
    'nixos-version | cut -d" " -f1; systemctl --failed --no-legend | wc -l'
done
```

Every container should report the new channel version and `0` failed units.
A transient failure during `switch-to-configuration` can disappear after the
unit finishes; re-check before investigating.

### Service checks

Adjust ports/paths only if the configuration changed.

| Container | Check |
| --- | --- |
| DNS | `dig +short @10.20.20.11 minnecker.com` and `dig +short @10.20.20.16 example.com` |
| PostgreSQL | `runuser -u postgres -- psql -tAc 'select 1'`, `pg_isready` |
| Forgejo | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/` (expect 200) |
| Forgejo runner | `systemctl is-active gitea-runner-default` |
| Matrix | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8008/_matrix/client/versions` (expect 200) |
| Vaultwarden | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/alive` (expect 200) |
| Wiki.js | `systemctl is-active wiki-js`; `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/` |
| Jitsi | `systemctl is-active prosody jicofo jitsi-videobridge2` |
| Monitoring | Prometheus `:9090/-/healthy`, Grafana `:3000`, Loki/alloy active |
| Open WebUI | `curl -g -s -o /dev/null -w '%{http_code}' http://[::1]:8080/health` (expect 200); startup log should contain `Initialized 1 tool server(s)` |
| nginx / webmail | `systemctl is-active nginx phpfpm-roundcube`; `curl -k -s -o /dev/null -w '%{http_code}' https://mail.minnecker.com/` (expect 302) |
| Mail | `postfix status`; `systemctl is-active postfix dovecot rspamd mail-api`; `postqueue -p` empty; `doveadm log errors` empty |
| Mail transport | `postconf -M` shows `smtp unix ... smtp` **and** `smtp inet ... postscreen` |
| IDM | `systemctl is-active kanidm`; `runuser -u kanidm -- <kanidmd> domain upgrade-check -c <server.toml>` reports the upgraded domain level and `PASS` |
| WireGuard | `wg show`; SSH through the tunnel still works |

Public endpoints (from outside the container network):

```bash
for u in https://idm.minnecker.com/ https://mail.minnecker.com/ \
         https://git.minnecker.com/ https://ai.minnecker.com/; do
  printf '%s ' "$u"
  curl -k -s -o /dev/null -m 15 -w '%{http_code}\n' "$u"
done
```

Expected: IDM `303`, webmail `302`, Forgejo and Open WebUI `200`.

### Mail end-to-end

Send one test message to an address you control (not to a third party) and
confirm SMTP acceptance in the log:

```bash
pct exec <mail-id> -- /run/current-system/sw/bin/bash -lc \
  "printf 'Subject: upgrade delivery test\n\n test\n' | sendmail -i -f user@example.org user@example.net"
journalctl -u postfix --since '-2 min' --no-pager | grep 'status=sent'
```

The log must show `relay=<MX>:25 ... status=sent (250 ...)`. If it shows
`relay=none ... mail transport unavailable`, fix the Postfix transport first
(see the build-time pitfalls).

## 4. Rollback

- **Configuration/runtime problem:** switch back to the previous NixOS
  generation in the affected container:

  ```bash
  pct exec <id> -- /run/current-system/sw/bin/bash -lc \
    'nixos-rebuild switch --rollback'
  ```

- **Catastrophic problem (database, identity data, failed domain upgrade):**
  restore the snapshot. This reverts the container to the state at snapshot
  time and discards changes made since then:

  ```bash
  pct stop <id>
  pct rollback <id> preupgrade-YYYYMMDD
  pct start <id>
  ```

- After a few days of normal operation, remove the snapshots to reclaim space:

  ```bash
  pct delsnapshot <id> preupgrade-YYYYMMDD
  ```

## 5. Secrets checklist

- Do not commit or paste secret values into logs, issues or this guide.
- Do not print secret files while debugging; reference their paths only.
- Do not disable authentication to "test" an upgrade. Use a normal logged-in
  user session or the service's own health endpoint.
- If a secret is accidentally printed or committed, rotate it immediately and
  remove it from the repository history.
