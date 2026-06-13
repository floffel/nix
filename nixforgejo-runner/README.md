# Forgejo Actions Runner Configuration (`nixforgejo-runner`)

This directory contains the NixOS configuration files for the Forgejo Actions runner container (`nixforgejo-runner`).

The runner executes CI/CD workflows using Docker containerization.

---

## 🛠️ Deployment Step-by-Step

---

### Step 1: Retrieve the Registration Token (from Forgejo Web UI)

1. Log into your Forgejo instance (e.g. `https://git.minnecker.com`) as an administrator.
2. Go to **Site Administration** -> **Actions** -> **Runners** (or visit `https://git.minnecker.com/admin/actions/runners`).
3. Click the **Create new Runner** button.
4. Copy the registration token displayed.

---

### Step 2: Configure Secrets and Switch (on `nixforgejo-runner`)

Log into the `nixforgejo-runner` container as root:

1. **Pull the latest configuration updates**:
   ```bash
   cd /root/nixos-config && git pull
   ```
2. **Execute the Secrets Setup Helper Script**:
   Provide the registration token copied in Step 1:
   ```bash
   ./scratch/setup-forgejo-runner-secrets.sh <RUNNER_REGISTRATION_TOKEN>
   ```
   *(This script automatically creates `/var/lib/secrets/forgejo` and configures the token file with secure permissions and ownership for the `gitea-runner` user).*
3. **Switch to the New Configuration**:
   ```bash
   nixos-rebuild switch
   ```

---

## 🐋 Runner Execution Environment

The runner is configured with the standard Docker daemon (`virtualisation.docker.enable = true;`) to execute actions step in isolated environments. The default labels are set to mapping standard runner versions (e.g., `ubuntu-latest`) to a Node.js Docker container image:

```nix
labels = [
  "ubuntu-latest:docker://node:20-bullseye"
  "ubuntu-22.04:docker://node:20-bullseye"
  "ubuntu-20.04:docker://node:20-bullseye"
  "native:host"
];
```
