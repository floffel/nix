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
