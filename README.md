# Proxmox NixOS Guest Containers Setup Guide

This repository contains a unified NixOS configuration for running a **Mail Server** and a **WireGuard Gateway** as unprivileged Proxmox LXC containers.

---

## 🚀 Quick Deployment Steps

Clone this repository inside your container (e.g. into `/root/nixos-config`), then run the command block for that specific container.

### 📬 Option A: Setup Mail Server Container
Run these commands inside the Mail Server LXC:

```bash
# 1. Clone the repository
git clone <your-repo-url> /root/nixos-config

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
git clone <your-repo-url> /root/nixos-config

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

Before running `nixos-rebuild switch`, you must place the credentials/keys on each server:

### For the Mail Server:
1. **LDAP Secrets**:
   Create the directory:
   ```bash
   mkdir -p /var/lib/secrets/mail && chmod 700 /var/lib/secrets/mail
   ```
   Create these 5 files inside `/var/lib/secrets/mail/` containing your LDAP configuration:
   - `postfix-ldap-aliases.cf`
   - `postfix-ldap-domains.cf`
   - `postfix-ldap-recipients.cf`
   - `postfix-ldap-senders.cf`
   - `dovecot-ldap.conf.ext`
   
   Ensure correct ownership:
   ```bash
   chown -R postfix:postfix /var/lib/secrets/mail/postfix-ldap-*.cf
   chown dovecot:dovecot /var/lib/secrets/mail/dovecot-ldap.conf.ext
   chmod 600 /var/lib/secrets/mail/*
   ```

2. **DKIM Keys**:
   Place your private key file at `/var/db/dkim/minnecker.com.private` and configure permissions:
   ```bash
   mkdir -p /var/db/dkim
   chmod 700 /var/db/dkim
   chown -R 182:182 /var/db/dkim # 182 is the rspamd user
   chmod 600 /var/db/dkim/minnecker.com.private
   ```

### For the WireGuard Server:
1. **WireGuard Private Key**:
   Place your WireGuard private key at `/var/lib/secrets/wireguard/private.key`:
   ```bash
   mkdir -p /var/lib/secrets/wireguard && chmod 700 /var/lib/secrets/wireguard
   echo "YOUR_PRIVATE_KEY" > /var/lib/secrets/wireguard/private.key
   chmod 600 /var/lib/secrets/wireguard/private.key
   ```
