# AGENTS.md — Operating Rules for This Repository

## Critical: never take down the network edge

`nixwireguard` (Proxmox CT **100**) is not just a VPN service. It is the
network path used to reach the Proxmox host and, in this setup, the SMB/NFS
storage that many containers and the host depend on. Stopping or rebooting
CT 100 from a remote session can cut **all** access and can deadlock storage
mounts. The host may then appear completely unreachable.

### Hard rules

1. **Never run `pct stop`, `pct reboot`, `pct shutdown`, or `pct reset` on
   CT 100 from a remote SSH session.** Use an out-of-band console (Proxmox/
   Hetzner console) and a planned maintenance window.
2. **Never change CT 100's network or mount configuration remotely** unless
   you have a verified second access path that does not depend on CT 100.
3. **Never add a mount to CT 100 whose source is only reachable through
   CT 100.** That is a circular dependency: the container cannot boot until
   the mount succeeds, and the mount cannot succeed until the container is up.
4. Any start/stop/reboot that can affect the edge must be run **detached from
   the SSH session**, for example:
   ```bash
   systemd-run --unit=restart-ct100 --collect --property=Type=oneshot \
     /usr/sbin/pct reboot 100
   ```
   Stopping the edge kills the SSH session; without a detached job the
   follow-up `pct start` may never execute.
5. Before network/storage changes: take a snapshot, verify the storage source
   does not depend on the container being changed, and confirm out-of-band
   access.
6. Never use a hard stop as a shortcut for applying an LXC mount change.
   Mount entries are applied on container start; prefer an out-of-band
   stop/start, or a bind mount performed inside the running container, and
   keep the old configuration available.

### If CT 100 is already down

From the Proxmox/OOB console:

```bash
pct status 100
pct unlock 100                  # if the status is "locked"
pct config 100 | grep mount     # inspect active mount entries
```

Remove any **newly added** mount line from the active section of
`/etc/pve/lxc/100.conf` (for example the CrowdSec shared-secrets mount) and
start it detached:

```bash
sed -i '\#/mnt/pve/nas/shared/secrets/crowdsec var/lib/secrets/crowdsec#d' /etc/pve/lxc/100.conf
systemd-run --unit=start-ct100 --collect --property=Type=oneshot \
  /usr/sbin/pct start 100
journalctl -u pve-container@100 -n 100
```

If the start hangs, inspect host storage before retrying:

```bash
dmesg | tail -50
mount | grep -E 'cifs|smb|nfs'
pct status 100
```

Do not repeatedly force-stop/start the container. Each attempt can hang on a
dead storage mount. Restore the storage path first, or start the container
without the dependent mounts.

### Monitoring and security changes

CrowdSec, exporters, Grafana and log shipping are safe to change on
non-edge containers. Do not attach new storage or network dependencies to
CT 100 while implementing them. The CrowdSec firewall bouncer on CT 100 must
be deployed only after the central LAPI and shared secret path are proven
reachable independently of CT 100.
