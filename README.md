# Proxmox NixOS Guest Containers Setup Guide

This repository contains a unified NixOS configuration for running a **Mail Server** and a **WireGuard Gateway** as unprivileged Proxmox LXC containers.

---

## 🚀 Quick Deployment Steps

Clone this repository inside your container (e.g. into `/root/nixos-config`), then run the command block for that specific container.

### 📬 Option A: Setup Mail Server Container
Run these commands inside the Mail Server LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/mail-server/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/mail-server/mail-server.nix /etc/nixos/mail-server.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets & DKIM (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

### 🔑 Option B: Setup WireGuard VPN Container
Run these commands inside the WireGuard LXC:

```bash
# 1. Clone the repository
git clone https://github.com/floffel/nix.git /root/nixos-config

# 2. Symlink configurations
ln -sf /root/nixos-config/wireguard/configuration.nix /etc/nixos/configuration.nix
ln -sf /root/nixos-config/common-lxc.nix /etc/nixos/common-lxc.nix
ln -sf /root/nixos-config/hosts.nix /etc/nixos/hosts.nix

# 3. Setup Secrets (see "Required Secrets" section below)

# 4. Rebuild the system
nixos-rebuild switch
```

---

## 🔒 Required Secrets & Prerequisites

Before running `nixos-rebuild switch`, you must place the credentials/keys on each server.
Or in my case, mount it into the secrets stores. Replace type with corresponding type, e.g. mail, wireguard...

Create the directory:
```bash
source /etc/set-environment
mkdir -p /var/lib/secrets/<type> && chmod 700 /var/lib/secrets/<type>
```

Then add the following line to the container config, e.g. `/etc/pve/lxc/<id>.conf`. Get the id by `pct list`.
```
lxc.mount.entry: /mnt/pve/nas/shared/secrets/<type> var/lib/secrets/<type> none bind,rw 0 0
```

### For the Mail Server:
1. **LDAP Secrets**:   
   Ensure correct ownership:
   ```bash
   chown postfix:postfix /var/lib/secrets/mail/*/*.cf
   chown dovecot:dovecot /var/lib/secrets/mail/dovecot/ldap.conf.ext
   chmod 600 /var/lib/secrets/mail/*
   ```

2. **DKIM Keys**:
   ```bash
   chown -R 182:182 /var/lib/secrets/dkim/ # 182 is the rspamd user
   chmod 600 /var/lib/secrets/dkim/*.private
   ```

### For the WireGuard Server:
1. **WireGuard Server Keys**:
   Generate a private and public key pair for the server:
   ```bash
   # Make sure the directory exists and has restricted permissions
   mkdir -p /var/lib/secrets/wireguard && chmod 700 /var/lib/secrets/wireguard
   
   # Generate private key
   nix-shell -p wireguard-tools --run "wg genkey" > /var/lib/secrets/wireguard/private.key
   chmod 600 /var/lib/secrets/wireguard/private.key

   # Generate public key (optional, useful for client configs)
   nix-shell -p wireguard-tools --run "wg pubkey" < /var/lib/secrets/wireguard/private.key > /var/lib/secrets/wireguard/public.key
   ```

2. **WireGuard Client Setup**:
   To connect a client (such as your phone or laptop) to this gateway, you need to set up a key pair on the client and register its public key on the server.
   
   * **Step A: Generate Client Keys**
     Generate a key pair on the client device. If using a command-line client:
     ```bash
     wg genkey | tee client_private.key | wg pubkey > client_public.key
     ```
     For graphical clients (like the iOS/Android WireGuard app), the app can generate these keys for you automatically.
   
   * **Step B: Register the Client's Public Key on the Server**
     Edit the WireGuard configuration file on the server (`/root/nixos-config/wireguard/configuration.nix`) and add the client's public key to the `peers` block:
     ```nix
     wg-quick.interfaces.wg0 = {
       ...
       peers = [
         {
           publicKey = "CLIENT_PUBLIC_KEY_HERE";
           allowedIPs = [ "10.100.0.2/32" ]; # Assign a static IP inside the tunnel to the client
         }
       ];
     };
     ```
     Then, run the rebuild command on the server to apply the configuration change:
     ```bash
     nixos-rebuild switch
     ```
   
   * **Step C: Create the Client Configuration**
     Configure the client device (e.g. in `/etc/wireguard/wg0.conf` or inside the WireGuard app) with:
     ```ini
     [Interface]
     Address = 10.100.0.2/24
     PrivateKey = <CLIENT_PRIVATE_KEY>
     DNS = 1.1.1.1 # Or your local DNS resolver IP
     
     [Peer]
     PublicKey = <SERVER_PUBLIC_KEY> # Get this by running: cat /var/lib/secrets/wireguard/public.key
     Endpoint = <SERVER_IP_OR_DOMAIN>:51820
     AllowedIPs = 0.0.0.0/0 # Or 10.100.0.0/24 to route only VPN traffic
     PersistentKeepalive = 25
     ```

---

## 🧰 Starting configuration for a new Proxmox LXC container

When you create a new Proxmox container for NixOS, use the following starting configuration as a minimal base. Edit (or create) `/etc/nixos/configuration.nix` inside the container using an editor like `nano` and paste the block below.

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

After saving `/etc/nixos/configuration.nix` (e.g. `sudo nano /etc/nixos/configuration.nix`) run these commands inside the container to load the environment, update channels, and rebuild the system:

```bash
# Load environment variables provided by Proxmox (if present)
source /etc/set-environment

# Update NixOS channels
sudo nix-channel --update

# Rebuild and upgrade the system
sudo nixos-rebuild switch --upgrade
```

Notes:
- Editing via `nano /etc/nixos/configuration.nix` is fine for quick setup; for reproducible deployments prefer managing the configuration from a git checkout and symlinking as shown earlier.
- If your container is unprivileged, some additional tweaks may be needed depending on your Proxmox setup.
