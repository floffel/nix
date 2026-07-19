# NixOS Configuration Audit Plan

## Summary

Audit of 18 NixOS configuration files across 13 LXC containers in a Proxmox-based infrastructure. Issues are categorized by severity: **Critical** (will prevent build/rebuild), **Warning** (likely to cause runtime issues or incorrect behavior), and **Minor** (suboptimal but functional).

---

## Issues Ordered by Priority

### 1. [Warning] `services.nsd.dnssec` option renamed to `zone-signing-schedules` mismatch

**Files:** `nixnsd/nsd.nix`
**Line:** 86-105

The config declares `signatures = dnssec` on each zone, where `dnssec = { enabled = true; keys = [...]; }`. The NixOS modules option for DNSSEC on NSD zones is accessed via `services.nsd.zones.<name>.dnssec` (boolean), not a custom `signatures` attribute. The module expects `services.nsd.zones.<name>.dnssecPolicy` for key management, not a custom `keys` attribute under a `dnssec` object.

**Fix:** Replace the custom `signatures` approach with the declarative NixOS `dnssecPolicy` submodule:
```nix
zones = {
  "minnecker.com" = {
    provideXFR = commonProvideXFR;
    notify = commonNotify;
    data = builtins.readFile ./zones/minnecker.com.forward;
    dnssecPolicy = {
      algorithm = "ecdsap256sha256";
      ksk.keySize = 256;
      zsk.keySize = 256;
    };
  };
  # ... repeat per zone
};
```

---

### 2. [Warning] `services.nsd.ratelimit` key is missing the `.enable` sub-attribute

**Files:** `nixnsd/nsd.nix`
**Line:** 66-69

```nix
ratelimit = {
    enable = true;
    ratelimit = 200;
};
```

The NixOS option `services.nsd.ratelimit` is a boolean (`Type: boolean`), not a submodule with an `enable` key. The sub-option is the parent itself (a boolean), and any value-setting should go in `services.nsd.ratelimit = true;` plus an additional mechanism for the rate limit count. However, NixOS NSD module does not expose a `ratelimit` value option — the rate limit is controlled via the underlying NSD configuration. The correct approach may need `services.nsd.extraConfig`.

**Fix:**
```nix
services.nsd.ratelimit = true;
services.nsd.extraConfig = "ratelimit: 200";
```

---

### 3. [Critical] `redisServers` option does not exist in NixOS options index

**Files:** `nixpostgres/postgresql.nix`
**Line:** 182-211

```nix
services.redisServers = { ... };
```

The MCP query returned "No options found" for `redisServers`. The correct NixOS option is `services.redis.servers` (attribute set of redis server configurations), not `redisServers`.

**Fix:** Replace with:
```nix
services.redis.servers.nextcloud = {
    enable = true;
    listen = "*";
    port = 6379;
    # ... rest of config as settings
};
```

---

### 4. [Warning] `services.nginx.package` with `module = [...]` pattern — module loading method

**Files:** `nixnginx/nginx.nix`
**Line:** 70-74

```nix
modules = [
    pkgs.nginxModules.brotli
    pkgs.nginxModules.njs
    nginx-auth-ldap
];
```

The `modules` attribute in `pkgs.nginx.override` is the correct way to add modules. However, building custom nginx with third-party C modules (like `nginx-auth-ldap`) requires careful handling. The derivation for `nginx-auth-ldap` does not include a `buildPhase` or `installPhase`, which means it defaults to running `make install`. This could fail if the module requires a different build process with nginx headers.

**Fix:** Ensure the `nginx-auth-ldap` derivation explicitly builds against the correct Nginx headers. Verify with a test build:
```nix
nginx-auth-ldap = pkgs.stdenv.mkDerivation rec {
    # ... add buildPhase and installPhase explicitly
    buildCommand = ''
        make PREFIX=$out INSTALL_PATH=$out/modules
        install -D modules/ngx_http_auth_ldap_module.so \
            $out/modules/ngx_http_auth_ldap_module.so
    '';
};
```

---

### 5. [Minor] `jitsy` typo in upstreams — variable name misspelled

**Files:** `nixnginx/nginx.nix`
**Line:** 121

```nix
jitsy.servers = { "nixjitsi:80" = {}; };
```

The variable name is `jitsy` (missing 'i') but the actual service/host is `nixjitsi`. This is a nginx upstream name in NixOS's declarative config, not a variable reference — the `servers` attribute is nested under this arbitrary name, so NixOS will generate an nginx upstream block named "jitsy" (the attribute set key). The resulting nginx config will have `upstream jitsy` rather than `upstream jitsi`. However, in the virtualHost for meet.minnecker.com (line 566), it correctly proxies to `http://jitsy`, which matches this upstream name. **This is not a bug** since the proxyPass uses `http://jitsy` which maps to the upstream named "jitsy", but it is a cosmetic inconsistency that could cause confusion.

**Fix (cosmetic):** Rename to `jitsi.servers` for consistency, and update the proxyPass in the virtualHost from `http://jitsy` to `http://jitsi`.

---

### 6. [Warning] Fail2ban `actionban`/`actionunban` override syntax

**Files:** `nixnginx/configuration.nix`
**Line:** 111-116

```nix
settings.actionban = ''iptables -I f2b-<name> 1 -s <ip> -j DROP'';
settings.actionunban = ''iptables -D f2b-<name> 1 -s <ip> -j DROP'';
```

These are global fail2ban settings that override the `actionban`/`actionunban` for ALL jails. The `<name>` placeholder refers to the jail name, which means each jail gets its own iptables chain (e.g., `f2b-nginx-oauth2-brute-force`). But the shared chain defined at line 130-134 is `f2b-nginx`. The jail chains won't automatically be part of the shared chain — you need to add `iptables -I f2b-nginx 0 -j f2b-<name>` rules, or the jails create independent chains that are never referenced.

**Fix:** Either add jump rules to wire jail-specific chains into the shared chain, or change `actionban` to reference `f2b-nginx` directly:
```nix
settings.actionban = ''iptables -I f2b-nginx 0 -s <ip> -j DROP'';
settings.actionunban = ''iptables -D f2b-nginx 0 -s <ip> -j DROP'';
```

---

### 7. [Warning] WireGuard interface uses `wg-quick` instead of modern `wireguard` module

**Files:** `nixvpn/configuration.nix`
**Line:** 29-83

```nix
wg-quick.interfaces.wg0 = { ... };
```

The `networking.wg-quick` module is deprecated in favor of `networking.wireguard`. The wg-quick interface format works but will have the `postUp`/`postDown` hooks managed by systemd-wait, which may behave differently inside LXC containers. The modern `networking.wireguard.interfaces` module is preferred and integrates better with systemd-networkd (used by Proxmox LXC).

**Fix:** Migrate to:
```nix
networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.1/24" ];
    listenPort = 51820;
    privateKeyFile = "/var/lib/secrets/nixvpn/private.key";
    mtu = 1360;
    peers = [ ... ];
};
```
For the postUp/postDown iptables rules, move them to `networking.firewall.extraRules` or keep a custom systemd service.

---

### 8. [Minor] `nixforgejo-runner` uses `gitea-actions-runner` (outdated package name)

**Files:** `nixforgejo-runner/runner.nix`
**Line:** 40-55

The config uses `services.gitea-actions-runner` which still exists in nixpkgs. However, the correct modern name (per MCP search) is `services.gitea-actions-runner` — this actually exists. No change needed, but it's worth noting that Gitea was rebranded as Forgejo; the runner package name `services.gitea-actions-runner` correctly maps to the gitea/forgejo ecosystem.

**No fix required.** Just a note for maintainability.

---

### 9. [Warning] `services.forgejo.postStart` modifies application state imperatively

**Files:** `nixforgejo/forgejo.nix`
**Line:** 98-138

The `postStart` hook runs a shell script every time Forgejo starts to register/update the OIDC auth source. This:
- Runs as root inside a forking postStart, potentially blocking the service startup
- Uses `forgejo admin auth` CLI which may not exist in all versions
- Race condition: if multiple instances start (e.g., during rolling update), both may try to register

**Fix:** Consider using `services.forgejo.settings` for auth source configuration, or at minimum add a lock file mechanism using `flock`.

---

### 10. [Minor] ACME postRun copies files imperatively instead of using NixOS mechanisms

**Files:** `nixnsd/acme.nix`
**Line:** 67-73

```nix
postRun = ''
    mkdir -p /var/lib/secrets/ssl/minnecker.com
    cp fullchain.pem ...
'';
```

The ACME certs are copied to `/var/lib/secrets/ssl/minnecker.com` imperatively in `postRun`. This means the paths are non-deterministic (could be lost on container restart if not bind-mounted). For declarative reproducibility, the certificates should either be bind-mounted or managed via `environment.etc`.

**Fix:** Since these files are also mounted read-only into consumer containers (nixnginx, nixidm, nixmail), this is actually a deliberate design choice for sharing certs across containers via NAS bind mounts. No change strictly required — but note that if the NAS mount is removed, cert copies on local disk persist (potential security concern).

---

### 11. [Minor] `stateVersion = "26.05"` — verify channel alignment

**Files:** All configurations
**Line:** varies

All configs use `system.stateVersion = "26.05"`. This should match the nixpkgs channel in use (or the closest matching release). Verify that this is a valid/current NixOS release. The latest documented releases at time of audit may differ.

**Fix:** Verify with `nixos-version` or channel info and update if necessary. Options like `services.alloy`, `services.matrix-synapse.extras` may not exist in older stateVersions.

---

### 12. [Minor] Unbound `tls-cert-bundle` points to server cert, not root CA

**Files:** `nixunbound/unbound.nix`
**Line:** 31-32

```nix
tls-cert-bundle = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
tls-key = "/var/lib/secrets/ssl/minnecker.com/key.pem";
```

The `tls-cert-bundle` in Unbound should be a CA bundle (root certificates), not a server certificate. For DNS-over-TLS, Unbound needs the server's certificate (fullchain.pem) for serving TLS to clients. However, `tls-cert-bundle` is documented as the path to a file containing trusted CA certificates — so clients connecting via DoT will verify against these CAs. For a server-side TLS setup, the cert/key pair is already referenced via `tls-cert-bundle` and `tls-key`. The actual naming in the Unbound module is:
- `tls-cert-bundle` for the CA bundle (not server cert)
- The server cert/key should be set via separate options

**Fix:** Check the NixOS Unbound module — it has specific `tlsCert` and `tlsKey` options. Replace the raw settings approach with:
```nix
tls = {
    certPath = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
    keyPath = "/var/lib/secrets/ssl/minnecker.com/key.pem";
};
```

---

### 13. [Minor] Nextcloud `extraApps` with `inherit (pkgs.nextcloud33Packages.apps) user_oidc` — version coupling

**Files:** `nixnginx/nginx.nix`
**Line:** 770-772

```nix
extraApps = {
    inherit (pkgs.nextcloud33Packages.apps) user_oidc;
};
```

This tightly couples the config to `nextcloud33Packages`. If nextcloud is upgraded, the package reference changes and this will fail at evaluation time.

**Fix:** Use `extraPackages = [ pkgs.nextcloud33.user_oidc ];` or a dynamic lookup.

---

### 14. [Minor] Missing InfluxDB bucket token file for Grafana Datasource

**Files:** `nixmonitoring/monitoring.nix`
**Line:** 320-324

Grafana datasource references `secureJsonData.token = "$__file{/var/lib/secrets/influxdb/token}"`, and `influxdb-init` writes to `$d/token`. But `grafana-secrets` creates the directory `/var/lib/secrets/grafana`, not `/var/lib/secrets/influxdb`. The InfluxDB init service creates it, but if `influxdb-init` fails (InfluxDB not ready), the token file won't exist, and Grafana's datasource provisioning will silently fail.

**Fix:** Add `after = [ "influxdb-init.service" ]` to Grafana's service config.

---

### 15. [Warning] Jitsi `permittedInsecurePackages` is a deprecated pattern

**Files:** `nixjitsi/jitsi.nix`
**Line:** 5-7

```nix
nixpkgs.config.permittedInsecurePackages = [
    "jitsi-meet-1.0.8792"
];
```

`permittedInsecurePackages` requires enabling `allowUnfreeAndCheckedBroken` and is deprecated. The better approach is to pin the nixpkgs channel version or use `nixpkgs.config.packageOverrides` for this specific package.

**Fix:** Either update to a patched version of jitsi-meet, or use `nixpkgs.config.permittedInsecurePackages` within a scoped override approach:
```nix
(nixpkgs.lib.overrideScope (self: super: {
    jitsi-meet = super.jitsi-meet.overrideAttrs (old: { ... patched ... });
}))
```

---

### 16. [Minor] `services.jitsi-videobridge.nat` — localAddress should not be hardcoded to container IP

**Files:** `nixjitsi/jitsi.nix`
**Line:** 51-58

```nix
services.jitsi-videobridge = {
    nat = {
        localAddress = "10.20.20.22";
        publicAddress = "meet.minnecker.com";
    };
};
```

Hardcoding the container IP (`10.20.20.22`) in the Nix config means changing container IPs requires updating both `hosts.nix` and this file.

**Fix:** Use `${config.networking.ip4addr}` or reference hosts.nix for the IP address to keep them in sync.

---

## Cross-cutting Concerns (Not bugs, but recommendations)

A. **Secret management:** All secrets follow a consistent pattern of shared NAS mounts — this is well-designed.

B. **Idempotent seeders:** The oneshot pattern for provisioning secrets (vaultwarden, grafana, wikijs, matrix) is consistent and well-implemented across all services.

C. **DNS resolution dependency chain:** nixunbound depends on nixnsd (stub zones), but there's no explicit restart ordering between these services.

D. **Monitoring gaps:** `nixforgejo-runner` and `nixvpn` are not listed in the Prometheus node_exporter targets (line 51-67 of monitoring.nix), meaning system metrics won't be collected for these containers.

E. **Fail2ban Redis dependency:** The fail2ban config on nixnginx references Redis on nixpostgres (line 36-37: `settings.redis-server = "nixpostgres"`), but there's no ordering guarantee that Redis on nixpostgres is available when fail2ban starts.
