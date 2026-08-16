# Mail stack: hardening + feature set (nixmail/nixnginx/nixnsd)

Implements, for `minnecker.com` mail (Postfix + Dovecot 2.4 + Rspamd + Roundcube, LDAP-backed by Kanidm):

1. MTA-STS + TLS-RPT (+ MTA-STS policy hosting)
2. Fix broken DKIM DNS record (`minnecker._domainkey`) + verify signature
3. ARC signing
4. DMARC/TLS-RPT report processing (parsedmarc)
5. Rspamd web UI (LDAP-protected) + scan history
6. Quarantine mailbox (tier-based, alias to postmaster + sieve)
7. Greylisting via postscreen
8. Sieve vacation/notify + recipient-delimiter auto-folder routing
9. Dovecot FTS (flatcurve)
10. Dovecot stats → Prometheus (textfile collector)
11. DKIM key provisioning in Nix (+ second selector for rotation, optional)
12. BIMI records + logo hosting (VMC out of scope)
13. per-mailbox `+`/`.` addressing docs (README)

**Explicitly out of scope per user**: quota, webmail (Roundcube exists at mail.minnecker.com).

Constraints recorded from the user:
- **No new LDAP users.** `quarantine@minnecker.com` and `reports@minnecker.com` are manually configured aliases to `postmaster@minnecker.com` (Kanidm, done by the user outside this repo); sieve routes them into dedicated folders.
- No remote Elasticsearch/Splunk/Redis; keep everything inside the container LAN.

## Decisions / design notes (required reading)

- **Native Rspamd `quarantine` action cannot be used with this stack.** Verified in rspamd `src/libserver/milter.c` (sends `SMFIR_QUARANTINE` 'q') and Postfix `postfix/src/milter/milter8.c` (maps 'q' → `"H…"` → `CLEANUP_FLAG_HOLD`): a quarantine verdict puts the message in the Postfix **hold queue**, not a mailbox. Do NOT set a `quarantine` score in `actions.conf`.
  - Instead: a **score-band quarantine tier** via a custom `milter_headers` routine that adds `X-Rspamd-Quarantine: yes` when `task:get_score() >= <quarantine_threshold>` (below the reject threshold), and a global `before` sieve that redirects such mail to `quarantine@minnecker.com`. Alias → postmaster inbox → sieve files into `Quarantine/`. Release = moving the message back in IMAP.
- **Production Rspamd milter is currently dead.** `nixmail.nix` sets `smtpd_milters = inet:127.0.0.1:11332` but never defines an `rspamd_proxy` worker (`services.rspamd.postfix.enable` is off). The NixOS module only creates the proxy worker when that flag is set. This must be fixed first (see T1); it also explains why the `X-Spam-*` headers the global spam sieve relies on can be missing in prod.
- **parsedmarc reads the postmaster mailbox over IMAP.** It needs postmaster's POSIX password in a plaintext secret file. One-time manual provisioning `echo -n '<pw>' > /mnt/pve/nas/shared/secrets/mail/parsedmarc/imap-password` (mode 600, rw mounted into nixmail). Digest mail is sent through our own submission (same creds).
- All DNS changes live in `nixnsd/zones/minnecker.com.forward` + serial bump + `nixos-rebuild switch` on nixnsd (zone is `builtins.readFile` at eval).
- Wildcard `* CNAME px` already resolves `rspamd.*`, `mta-sts.*`, `bimi.*` to the nginx proxy container; relabel only if an explicit record is added.
- Dovecot is 2.4 (`dovecot_config_version = "2.4.4"`); plugin settings go under `settings.plugin` as an attrset (module renders a `plugin { }` section). Sieve 2.4 options are `settings.sieve_extensions` / `settings.sieve_global_extensions` (list of strings), scripts via `settings."sieve_script <name>"`.

## Task order (dependency-respecting; each task = deployable slice)

### S0. Pre-flight fixes (do first)
- **Fix the production milter:** add `services.rspamd.workers.rspamd_proxy` in `nixmail/nixmail.nix` bound to `127.0.0.1:11332` with `extraConfig` `upstream "local" { default = yes; self_scan = yes; }` (mirror `tests/mail-roundtrip.nix:48-56`). Optionally disable the `normal` worker or leave it. Verify mail actually flows through Rspamd in prod (mail header contains rspamd symbols).
- Fix `settings.main.smtpd_helo_restrictions`? No change. Ensure `milter_default_action = accept` so a flaky milter never tempfails delivery (add to `settings.main`).

### T1. nixmail — Rspamd: milter fix, WebUI, history, quarantine tier, ARC, DKIM provisioning, greylist-promotion of bayes
Files: `nixmail/nixmail.nix`, secrets on NAS, `tests/mail-roundtrip.nix`, `tests/test-helpers.nix`.

1. **Redis for rspamd** (history + stats + bayes): add `services.redis` on nixmail, bind `127.0.0.1`, unix socket optional; `services.rspamd.locals."redis.conf"` → `servers = "127.0.0.1:6379";`.
2. **Worker wiring:**
   - `rspamd_proxy` on `inet:127.0.0.1:11332` (milter, self-scan upstream) as in S0.
   - `controller` worker: `bindSockets = [ "[::]:11334" ]`, plus `local.d/worker-controller.inc` with `secure_ip = ["127.0.0.1" "10.20.20.14" "fd01::14"];` and `password = "…";` + `enable_password = "…";` generated on first boot by a new oneshot (`rspamadm pw`) writing `/var/lib/secrets/mail/rspamd/controller-password` (secrets mount is rw on nixmail).
   - Keep `normal` worker default.
3. **History module:** `local.d/history_redis.conf` with the local Redis (enables WebUI history/graphs).
4. **WebUI content:** verify `pkgs.rspamd` (3.x on nixos-26.05) ships the UI served by the controller (`curl http://127.0.0.1:11334/` in VM). If not, use `pkgs.rspamd-ui`-equivalent: do NOT add new package splits without checking; report back if the packaged UI is absent.
5. **DKIM/ARC keys:**
   - New oneshot `mail-dkim-key` (wantedBy `rspamd.service`, `before = ["rspamd.service"]`): if missing, `openssl genrsa 2048` (or `rspamadm dkim_keygen`) → `/var/lib/secrets/mail/dkim/minnecker.com.private` (+ `.public`), chown `rspamd:rspamd`, `chmod 600`; write `minnecker.dns` hint file containing the `minnecker._domainkey` TXT record and an `arc._domainkey` TXT (same key) for the operator to paste into the zone. Idempotent. Optional: `minnecker2` standby key for rotation (same service, guard on missing).
   - `local.d/dkim_signing.conf`: keep `selector = "minnecker"`, point `path` at the managed key path. Add `local.d/arc.conf` with same domain/key + `selector = "arc"`.
   - Update `tests/test-helpers.nix` only if the generator service needs the path (it already seeds a placeholder; keep compatible).
6. **Quarantine tier:**
   - `local.d/actions.conf`: `add_header = 6;` `reject = 40;` (raise reject so the band 12–39.99 can quarantine instead of bounce; exact numbers TBD by operator).
   - `local.d/milter_headers.conf`: `use = ["spam-header", "quarantine-flag"];` plus `extended_spam_headers = true;` and a `custom` routine `quarantine-flag` adding `X-Rspamd-Quarantine: yes` when `task:get_score() >= 12`.
   - Global sieve rule (see T5) redirects those to `quarantine@minnecker.com`.
   - Guard against redirect loop: sieve must `fileinto "Quarantine"` for `quarantine@minnecker.com` recipients BEFORE the redirect rule.
7. **Outbound settings hack (flagged):** do NOT enable `quarantine` action anywhere in `actions.conf` (would HOLD on Postfix).

### T2. nixmail — Postfix: greylisting, transports, postscreen tuning
File: `nixmail/nixmail.nix` `settings.main`:
- `postscreen_greylist_action = "enforce";`
- `postscreen_greylist_intervals = "1h:2h:4h";`
- `postscreen_dnsbl_sites = "zen.spamhaus.org=127.0.0.[2..11]*3,bl.spamcop.net=127.0.0.2*2";` (optional, matches existing RBL usage)
- `milter_default_action = "accept";`
- Leave `smtpd_recipient_restrictions` / `defer_unauth_destination` untouched (open-relay check depends on it).
- No new transport maps (quarantine is header/sieve-based).

### T3. nixmail — Dovecot: FTS, stats exporter, sieve extensions + routing scripts, quarantine/report folders
File: `nixmail/nixmail.nix`, `environment.etc."dovecot/…sieve"`.

1. **FTS (flatcurve, bundled):**
   - `settings.plugin.fts = "flatcurve";` + `settings.plugin.fts_flatcurve_*` tuning keys as confirmed by `doveconf -a` in VM.
   - `"protocol imap".mail_plugins = "$mail_plugins fts"`; `settings.plugin.fts_autoindex = yes;` + indexer: `"service indexer" = { process_limit = 1; ... }` and `"service indexer-worker"` idle limit.
   - Wait — **the `settings.plugin` option is marked “2.3-only”** in the module; validate in the VM with `doveconf -a`/`doveadm` that the emitted `plugin {}` section is honored by Dovecot 2.4. If it is not, emit the same keys via `services.dovecot2.settings."plugin fts" = { … }`? — the freeform renderer splits on first space, so the correct cross-version form is `services.dovecot2.settings.plugin = { fts = …; }`; adjust only after a VM check.
2. **Stats exporter (textfile):**
   - New systemd timer+service `dovecot-stats-exporter` (every 60s) running `doveadm stats dump` (or `doveadm stats dump --format prometheus`; fall back to parsing `key=value`) into `/var/lib/node-exporter-textfile/dovecot.prom` (write as `root` then chown `node-exporter`, or set `User=node-exporter` + `SupplementaryGroups` to read the dovecot unix socket).
   - Already scraped: Prometheus `node` job includes `nixmail:9100` and node_exporter has the textfile collector (`common-lxc.nix`).
3. **Sieve extensions + routing scripts:**
   - `settings.sieve_extensions = [ "envelope" "notify" "vacation" ];` (frees `vacation`/`notify` for user scripts).
   - New global `before` script **routing** (`settings."sieve_script routing"` `type="before"`): (a) `quarantine@` recipient → `fileinto :create "Quarantine"; stop;` (b) `X-Rspamd-Quarantine: yes` → `redirect "quarantine@minnecker.com"; discard; stop;` (c) `envelope :detail "to"` non-null → `fileinto :create "tags/<detail>"` — sanitize detail (strip `.`/`+`, forbid path traversal); (d) existing spam → `"Junk"` rule stays in `global-spam.sieve`.
   - New global script for **reports**: to/`original_recipient` `.reports`-style → move DMARC/TLS-RPT aggregate mail to folder `".Reports"` (`fileinto :create ".Reports"`). This lets parsedmarc watch only that folder.
   - `settings.sieve_script_bin_path` already handled by module default for 2.4 (verify `/tmp/dovecot-%{user|…}`).
4. **Vacation/notify starter:** ship a default per-user `sieve/` skeleton via Roundcube already present; add README with vacation snippet (no user data touched).

### T4. nixmail — parsedmarc service (DMARC + TLS-RPT processing)
- Enable `services.parsedmarc` (`enable = true`).
- `settings`: 
  - `imap.host = "127.0.0.1"; imap.port = 143; imap.ssl = false; imap.user = "postmaster@minnecker.com"; imap.password = { _secret = "/var/lib/secrets/mail/parsedmarc/imap-password"; };`
  - `mailbox.watch = true; mailbox.delete = false;` (archive not delete)
  - `smtp.host = "127.0.0.1"; smtp.port = 587; smtp.ssl = false; smtp.user/from = "reports@minnecker.com"; smtp.to = ["florian@minnecker.com"];` + password secret (same file). Digest recipients per user.
  - Save parsed data: `save_aggregate/save_forensic` with NO Elasticsearch → parsedmarc stores reports in its folder via `s3`/files? (If model requires a sink, leave disabled and rely on the digest + archived raw reports in `".Reports"`.)
- `services.parsedmarc.provision.*` (localMail/Elasticsearch/GeoIP/Grafana) remain disabled — they conflict with our LDAP virtual mail flow.
- Provisioning notes: (a) operator adds `reports@minnecker.com` → postmaster alias in Kanidm (manual); (b) places postmaster password secret on NAS; (c) points TLS-RPT rua at `reports@` (T6). Put all three in README.

### T5. nixnginx — vhosts: `rspamd.minnecker.com` + `mta-sts.minnecker.com`
File: `nixnginx/nginx.nix` (+ `flake.nix` routing assertions).

1. Upstreams: `nixmail.servers = { "nixmail:11334" = {}; };`.
2. Vhost `rspamd.minnecker.com` (forceSSL, wildcard cert): `/` → `proxyPass = "http://nixmail"` + `proxyWebsockets = true` + **LDAP auth** identical to `ki.minnecker.com` (`auth_ldap "Forbidden"; auth_ldap_servers mail_users;`), plus `X-Forwarded-Proto`, and `proxy_set_header X-Forwarded-For ""` where the rspamd FAQ recommends (controller should see the real client for `secure_ip` decisions).
3. Vhost `mta-sts.minnecker.com` (forceSSL, wildcard cert): exact-string location `= /.well-known/mta-sts.txt` returning the policy:
   ```
   version: STSv1
   mode: enforce
   mx: riese.minnecker.com
   max_age: 86400
   ```
   (`# mx: backendmail.minnecker.com` if you prefer the canonical hostname; keep consistent with MX). Static via `pkgs.writeText` root or inline `return 200` — reviewer determines whether a static `root` vhost is simpler than location `return 200 body`; ensure `Content-Type: text/plain`.
4. `flake.nix` `nginxRoutingAssertions`: add `checkVhost "rspamd.minnecker.com"` (proxyPass `http://nixmail` + forceSSL) and `checkVhost "mta-sts.minnecker.com"` (forceSSL + has `= /.well-known/mta-sts.txt` location), with matching errorMsgs.

### T6. nixnsd — DNS: DKIM fix, ARC, MTA-STS, TLS-RPT, BIMI
File: `nixnsd/zones/minnecker.com.forward` (+ bump SOA serial to `2026081101` or next day after edits).

1. Fix DKIM owner name: replace `minnecker.com._domainkey IN TXT` → `minnecker._domainkey IN TXT  ( "v=DKIM1; k=rsa; " "p=<pubkey>" )`. Keep the existing public key until the T1 `mail-dkim-key` oneshot rotates it; after rotation the operator pastes the fresh key from `/var/lib/secrets/mail/dkim/minnecker.dns` (both selector records) and bumps serial again.
2. Add:
   - `arc._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=<same pubkey>" ) ; ARC selector`
   - `_mta-sts IN TXT "v=STSv1; id=2026081101"`
   - `_smtp._tls IN TXT "v=TLSRPTv1; rua=mailto:reports@minnecker.com"`
   - `mta-sts IN CNAME px`   (explicit; only needed if you don't want to rely on wildcard)
   - `default._bimi IN TXT "v=BIMI1; l=https://www.minnecker.com/bimi-logo.svg"` (+ host the SVG `bimi-logo.svg` on the `www.minnecker.com` static vhost; document that VMC is required for Gmail to honor Blue Verified Mark, i.e. this is a pre-VMC stub).
3. Update `_autodiscover`/`@@autoconfig`? Not in scope.
4. Validation: `nix flake check` picks up zone change via `mkCheck nixnsd`; add a lightweight eval-time assert that the zone text contains `minnecker._domainkey` and NOT `minnecker.com._domainkey`, plus `_mta-sts`/`_smtp._tls`/`arc._domainkey` (see T8).

### T7. README + per-address docs
- Secrets table: add `parsedmarc` password file (NAS path + mode), `rspamd/controller-password` (generated on host).
- Add section: recipient-delimiter addressing (`user+tag@` / `user.tag@`), automatic `tags/<tag>` folders, quarantine tier behavior and `quarantine@` alias, report-collection (`reports@` + digest), WebUI URL/auth, MTA-STS/TLS-RPT/DKIM-ARC provisioning + how to rotate the DKIM key (generate → paste DNS → deploy).
- Note the archived DMARC/TLS-RPT reports folder `.Reports` in postmaster inbox (rotation + retention via `global-spam`-style `after` script optional).

### T8. Tests (all layers)
- `tests/mail-roundtrip.nix` (extend): 
  - after sending the existing self-delivery, additionally submit to `testuser+news@minnecker.com` over SMTP and assert via `doveadm`/`find` the message lands in `tags/news/` (validates the routing sieve).
  - simulate quarantine redirect: craft a message with `X-Rspamd-Quarantine: yes` delivered to `quarantine@minnecker.com` and assert it lands in `Quarantine/` (validate the loop guard by asserting only ONE copy exists).
  - asserts `doveadm stats dump` exits 0 and `doveadm fts rescan`/`doveadm fts search` works; `rspamadm configtest` passes; `curl` on `127.0.0.1:11334/` returns 200.
  - keep existing open-relay / bad-password / port25 assertions; stay on port 587 for SMTP tests (greylisting only affects 25).
- `tests/test-helpers.nix`: seed `parsedmarc` password file + `rspamd` controller password file (or make the oneshots generate in VM like `kie-proxy-token`).
- `flake.nix` eval checks: extend `mailSecurityAssertions` minimally (e.g. assert `postscreen_greylist_action = enforce` present; assert `milter_default_action = accept`); add `dns-email-records` `mkAssertCheck` reading the zone file text; extend `nginxRoutingAssertions` (T5).
- `just test`, `just lint`, `nix flake check` all green; optionally `just test-vm`.

## Validation checklist at the end
1. `nix flake check` (eval + asserts) green.
2. VM: `vm-mail-roundtrip` passes with new assertions; `vm-nixmail`, `vm-nixnginx`, `vm-nixnsd`, `vm-nixmonitoring` still pass.
3. Outbound mail from several providers shows DKIM pass on `minnecker._domainkey` (`dig TXT minnecker._domainkey.minnecker.com`).
4. ARC header on self-sent mail (`arc._domainkey`).
5. `https://mta-sts.minnecker.com/.well-known/mta-sts.txt` reachable; `_mta-sts` + `_smtp._tls` records resolve; optional mta-sts tester (e.g. `mta-sts` debug tool) passes.
6. `https://rspamd.minnecker.com` shows the WebUI with LDAP login; History tab populated; quarantine tier test above works.
7. Greylisting active on port 25 (foreign IP, second attempt passes); existing relay protections unchanged.
8. `doveadm fts search`, `doveadm stats` + Prometheus metric `node_textfile_dovecot_*` present in Grafana; FTS folder full-text search in Roundcube works.
9. Vacations + `user+tag@` folder routing demoed; README updated.

## Open items / risk callouts (hand to implementer)
- Exact `settings.plugin` rendering on Dovecot 2.4 and `doveadm stats dump` prometheus output format must be verified in-VM before finalizing config; fallbacks documented above.
- Rspamd WebUI bundling on `nixos-26.05` needs runtime confirmation.
- Quarantine threshold (12) and reject threshold (40) are starting points; tune after observing real scores (`X-Spamd-Result` logs).
- DKIM rotation: publish DNS only AFTER the new key file is installed on the NAS path; keep the selectors consistent (post-rotation key must match the DNS TXT the operator pastes).
- TLS-RPT rua changes require the `reports@` alias + parsedmarc to be live first (order T4 before the DNS record update, or accept a short unmonitored window).