# Forgejo Actions Runner Configuration (`nixforgejo-runner`)

This directory contains the NixOS configuration files for the Forgejo Actions runner container (`nixforgejo-runner`).

The runner executes CI/CD workflows using Docker containerization.

> **Trust boundary:** workflows can execute repository code with access to the
> runner's Docker daemon and the `native` host label. Do not run untrusted pull
> requests on this runner; require approval for external contributors and never
> store production credentials in the runner container.

---

## Deployment Step-by-Step

---

### Step 1: Create the Runner in Forgejo (Web UI)

1. Log into your Forgejo instance (e.g. `https://git.minnecker.com`) as an administrator.
2. Go to **Site Administration** -> **Actions** -> **Runners** (or visit `https://git.minnecker.com/admin/actions/runners`).
3. Click the **Create new Runner** button.
4. Enter a name and description, then click **Create**.
5. Copy the **UUID** and **Token** displayed. These are one-time secrets. Do not paste real values into this repository or any ticket:
   ```
   UUID:  <runner-uuid>
   Token: <runner-token>
   ```

   If a real token has ever been committed, create a new runner registration and revoke the old token.

---

### Step 2: Configure Secrets and Switch (on `nixforgejo-runner`)

Log into the `nixforgejo-runner` container as root:

1. **Pull the latest configuration updates**:
   ```bash
   cd /root/nixos-config && git pull
   ```
2. **Execute the Secrets Setup Helper Script**:
   Provide the UUID and Token copied in Step 1:
   ```bash
   ./scratch/setup-forgejo-runner-secrets.sh <UUID> <TOKEN>
   ```
3. **Switch to the New Configuration**:
   ```bash
   nixos-rebuild switch
   ```

---

## Runner Execution Environment

The runner is configured with the standard Docker daemon (`virtualisation.docker.enable = true;`) to execute actions steps in isolated environments. The default labels are set to mapping standard runner versions (e.g., `ubuntu-latest`) to a Node.js Docker container image:

```nix
labels = [
  "ubuntu-latest:docker://node:20-bullseye"
  "ubuntu-22.04:docker://node:20-bullseye"
  "ubuntu-20.04:docker://node:20-bullseye"
  "native:host"
];
```

---

## CI Storage Layout

Docker's data root is **not** inside the container rootfs. It lives on a
separate Proxmox volume with its own quota:

| Path in CT 108        | Volume                     | Pool  | Quota |
| --------------------- | -------------------------- | ----- | ----- |
| `/var/lib/docker`     | (removed, see below)       | `fast`| none  |
| `/var/lib/ci-docker`  | `fast:subvol-108-mp-0`     | `fast`| 250 GiB |

Reason: every container rootfs on px is a dataset of the same `fast` pool, so
leaked Actions volumes did not just grow the runner -- on 2026-11-26 and
2026-11-27 they filled the pool to zero, and postgres, mail, Nextcloud and
Forgejo all died at once. A separate dataset with a `refquota` bounds the
damage CI can do to CI's own volume.

`fast` (NVMe, mirrored) is deliberate: the other zfspool storage `zfs` is a
mirror of 7200 rpm HDDs and would slow every build down.

The volume is created and attached out of band (NixOS cannot manage Proxmox
volume attachments), so recreating a host from this repo alone is not enough:

```bash
# dataset: name must match PVE's zfspool pattern subvol-<vmid>-*
zfs create -o refquota=250G fast/subvol-108-mp-0
pct stop 108
pct set 108 -mp0 fast:subvol-108-mp-0,size=250G,mp=/var/lib/ci-docker,backup=0
pct start 108
```

`runner.nix` sets `virtualisation.docker.daemon.settings.data-root` to
`/var/lib/ci-docker/docker` and adds an `ExecStartPre` guard that fails
`docker.service` when `/var/lib/ci-docker` is not a separate device. That is
intentional: silently falling back to the rootfs reproduces the outage while
looking healthy. If the guard fires, re-attach the volume -- do not remove the
guard. `CiVolumeNotMounted` in `nixmonitoring/prometheus-alerts.yml` pages on
the same condition.

The two named caches `ci-sccache` and `ci-lambda-binaries` are whitelisted in
`baseConfig` and must survive cleanup; they hold the compile cache and the
Lambda binaries, and re-downloading them costs S3 egress. The hourly
`forgejo-runner-volume-gc` unit therefore collects by name shape (hex job
volumes) instead of running `docker system prune --volumes`.
