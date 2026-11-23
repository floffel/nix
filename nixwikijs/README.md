# nixwikijs — Wiki.js (CT 111)

Personal wiki. Everything below the config line is data, so this file records
where the data came from and how it was checked.

* URL: <https://wiki.minnecker.com> (wildcard cert, proxied by `nixnginx`)
* Container: `nixwikijs`, CT **111**
* Database: postgres `wikijs` on `nixpostgres` (CT 107); the password lives in
  `/var/lib/secrets/postgres/wikijs/db-password` and is injected through the
  `wikijs-secrets` unit — see [`wikijs.nix`](wikijs.nix)
* Version: Wiki.js 2.5.312 (nixpkgs), schema migrations through `2.5.128.js`

## Content: imported from the retired box, not re-created

The old wiki ran Wiki.js on **sqlite** inside a container on saver CT 107
(`/root/container/wikijs/data/wikijs/config/db.sqlite`). It had Git sync turned
on against the old Gitea (`floffel/wikijs`), but that sync quietly stopped at
commit `2025-03-14 21:47` — six pages and one asset existed *only* in the sqlite
file, newest edit 2026-11-17.

On 2026-11-23 the sqlite database was converted and loaded into postgres with
[`../scratch/wikijs-sqlite-import.py`](../scratch/wikijs-sqlite-import.py):

| | |
| :--- | :--- |
| pages | 29 (27 markdown, 2 html) |
| revisions | 341 |
| tree nodes | 40 |
| assets | 9 (6.1 MB, incl. two PDFs) |
| locales | `de` added (`en` was already seeded) |
| navigation | 1 (`site`, tree mode) |

Verification, old sqlite vs new postgres, all identical:

* `md5` over `id|path|md5(content)` of every page → `366c5ae5a2729dbdfc276780db19fdde`
* same over `pageHistory` → `ed260e84285e86ab4a26dc45854eb3ee`
* same over `pageTree` → `afb5f9d97e69f81202733359c73ead78`
* same over `assetData` joined to filenames → `715e9d0760388ed6378cf1b818b68934`
* `navigation.config` byte-identical
* through the edge: `/home`, `Häuser/aktuell`, `midea-vacuum-robot`,
  `Häuser/Reihenhaus/Finanzierung`, `Arbeit/Scrum` → 200, unknown path → 404,
  and the four largest assets download at their recorded byte sizes

Rollback point: the pre-import (empty) database dump is
`/var/lib/px-archive/saver-2026-11-22/wikijs-new-empty-db-pre-import.sql`, and
the original sqlite file is in `wikijs-data.tar` in the same archive, pinned by
the `archive`-tagged restic snapshots.

## Settings

Ported from the old box because they are the user's own configuration: `lang`
(`de`, namespace `de`), `nav`, `logoUrl`, `pageExtensions`, `security`, `seo`
(`nofollow,noindex`), `features`, `theming`, `title`, `editShortcuts`, `company`,
`contentLicense`, `footerOverride`.

Deliberately **not** ported: `auth` (this box authenticates against Kanidm),
`certs`/JWK, `host`, `mail`, `sessionSecret`, `telemetry`. Those are per-instance
and the old values would have broken SSO.

## Permissions: copied by hand, because they are data too

Two group facts live in the database, not in the config, and both were wrong on
the new box until they were copied over:

* **`Guests` was open.** The new install seeded `read:pages`, `read:assets`,
  `read:comments` plus an allow-all page rule, so right after the content import
  every page and every uploaded asset was world-readable
  (`GET /Häuser/Reihenhaus/Finanzierung` and the Exposé PDF both answered from the
  public internet). The retired box had `permissions: []` and a
  `deny` page rule for `START` — private. Both were copied over; unauthenticated
  requests now behave exactly as before: `/home` → `302 /login`, page →
  `Unauthorized`, asset → `403`.
* **`florian@minnecker.com` had no group.** Wiki.js only ships Administrators
  and Guests, and the Kanidm-mapped user was in neither, so it could not read
  anything. The `userGroups` row mapping that user to Administrators was
  imported from the old box.

Worth remembering: a content-only migration silently carries the *new* box's
default ACLs with it. Diff `groups` and `userGroups` too.

## Open item: Git sync is off

`storage.git` is disabled here, so page edits are not versioned any more. The
old repo `florian/wikijs` on Forgejo still holds 340 commits of edit history up
to 2025-03-14 and would be the natural target if sync is switched back on —
worth doing, because silent sync failure is exactly what nearly lost these pages.
