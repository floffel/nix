# Fix Nextcloud build error on nixnginx container (rev. 2)

## Status

The previous plan's vhost restore was applied (good — the `cloud.minnecker.com`
vhost with fastcgi is back, lines 205–239). But the build now fails:

```
error: The option `services.nextcloud.cgi' does not exist. Definition values:
       - In `/root/nixos-config/nixnginx/nginx.nix': { enable = true; }
       Did you mean `services.nextcloud.cli', `services.nextcloud.cron' or `services.nextcloud.nginx'?
```

## Root cause

Two wrong options were added to `services.nextcloud` and one header typo was
introduced in the restored vhost.

Reference for the correct values: commit `fc98c40` is the last commit where
this exact `nixnginx/nginx.nix` nextcloud config built and worked. It used
`nginx.enable = false` (NOT `configureNginx`, and there is NO `cgi` option) plus
the manual fastcgi vhost. Verified via `git show fc98c40:nixnginx/nginx.nix`.
(The `config.services.phpfpm.pools.nextcloud.socket` pool exists even with
`nginx.enable = false` — fc98c40 proves it.)

## Changes to `nixnginx/nginx.nix`

### 1. Fix the build error (lines 706–707)

Replace:
```nix
    configureNginx = false;
    cgi.enable = true;
```
with:
```nix
    nginx.enable = false;
```

- `cgi.enable = true` is the option that does not exist → remove it (this is
  the reported error).
- `configureNginx` is the deprecated/old name for nextcloud; the canonical,
  proven-working option on this NixOS module is `nginx.enable = false`
  (matches fc98c40). Use that and drop the `configureNginx` line.
- Do NOT add any `cgi`/`phpfpm` toggle: the nextcloud module always creates
  the `phpfpm.pools.nextcloud` pool, which the vhost references.

### 2. Fix the XSS header typo (line 222)

Replace:
```
          add_header X-XSS-Protection "1; mode:block";
```
with:
```
          add_header X-XSS-Protection "1; mode=block" always;
```
(Equals sign `mode=block`, not colon; add trailing `always` to match the
original fc98c40 vhost. Not a build-breaker, but restores correct header
semantics.)

## What is already correct (do not touch)

- The `cloud.minnecker.com` vhost (lines 205–239): `root`, `try_files`,
  `fastcgi_pass unix:${config.services.phpfpm.pools.nextcloud.socket}`,
  `fastcgi_split_path_info`, security headers — all match fc98c40.
- Roundcube's `configureNginx = false` (line ~629) is a DIFFERENT module and
  is valid; leave it.

## Validation after deploy

1. `nixos-rebuild build` / the container build succeeds (no `cgi` option
   error, no `configureNginx` error).
2. `nginx -t` passes inside the container.
3. `https://cloud.minnecker.com` loads the Nextcloud page / redirects to
   Kanidm OIDC.
4. `journalctl -u nginx.service --no-pager | grep -i cloud.minnecker` — no
   FastCGI errors; `nextcloud-occ status` reports OK.

## Files changed

- `nixnginx/nginx.nix`: lines 706–707 (options) and line 222 (header typo).
