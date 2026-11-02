# NixOS Service Configuration for Paperless-ngx (nixpaperless)
#
# Migrated 2026-11-02 from the old Arch install on saver CT 110 (native venv +
# valkey + SQLite, config in /etc/paperless.conf).  Two things changed on the
# way over, everything else is carried across 1:1:
#
#   * SQLite -> PostgreSQL on nixpostgres, like every other stateful service in
#     this repository.  Done with paperless' own document_exporter /
#     document_importer pair, which is the supported cross-database path and
#     which also carries users, groups, permissions, saved views, correspondents,
#     tags and custom fields (the manifest is a full Django dump, including
#     auth.User — password hashes are portable, so logins keep working).
#   * Secrets follow the repository convention: the DB password is *shared*
#     (written by nixpostgresql to /var/lib/secrets/postgres/paperless and
#     bind-mounted read-only here), the Django secret key is *container-local*
#     and lives in dataDir, where the module keeps it and where vzdump/restic
#     back it up.
{ config, pkgs, lib, ... }:

let
  # Blank-page removal for scanned PDFs, run by the consumer before a document
  # is OCR'd and stored.  The script itself sits next to this file (ported from
  # the old /usr/bin/del_empty_pages.sh); it needs bash plus a handful of PDF
  # tools a paperless unit does not otherwise carry, so wrap it in a store
  # derivation that hard-codes them on PATH.  Paperless execs the script
  # directly (no shell), hence the explicit bash shebang.
  delEmptyPages = pkgs.writeTextFile {
    name = "del-empty-pages";
    destination = "/bin/del-empty-pages";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      export PATH=${lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.file
        pkgs.gawk
        pkgs.gnused
        pkgs.ghostscript
        pkgs.poppler-utils
        pkgs.qpdf
      ]}
    ''
    + builtins.readFile ./del-empty-pages.sh;
  };

  # The four paperless units all read the same EnvironmentFile, so all four
  # need the assembler to have run first.  A missing file is a hard systemd
  # failure (no "-" prefix), which is exactly what we want: paperless must not
  # come up against a database it cannot authenticate to.
  paperlessUnits = [
    "paperless-scheduler.service"
    "paperless-web.service"
    "paperless-task-queue.service"
    "paperless-consumer.service"
  ];
in
{
  services.paperless = {
    enable = true;

    # Dual-stack listen so nixnginx reaches it over either family (the same
    # choice nixwikijs makes).  Public access only ever happens through
    # nixnginx; nothing here is exposed directly.
    address = "::";
    port = 8000;

    environmentFile = "/run/paperless/env";

    settings = {
      PAPERLESS_URL = "https://paperless.minnecker.com";

      # Remote PostgreSQL on nixpostgresql (hosts.nix alias: nixpostgres).
      # PAPERLESS_DBPASS comes from environmentFile, never from the store.
      PAPERLESS_DBHOST = "nixpostgres";
      PAPERLESS_DBNAME = "paperless";
      PAPERLESS_DBUSER = "paperless";

      # Carried over from /etc/paperless.conf on the old box.
      PAPERLESS_WEBSERVER_WORKERS = 2;
      PAPERLESS_CONSUMER_ENABLE_BARCODES = true;
      PAPERLESS_SCRATCH_DIR = "/var/lib/paperless/uploads";
      PAPERLESS_PRE_CONSUME_SCRIPT = "${delEmptyPages}/bin/del-empty-pages";
    };
  };

  # Assemble the runtime env file from the DB password on the shared Postgres
  # secrets mount (provisioned by nixpostgresql's postgres-provision-passwords
  # unit), mirroring the wikijs-secrets / vaultwarden-secrets pattern.  Wanted
  # by — and ordered before — every paperless unit, so a restart of any of them
  # re-reads a rotated password.  No partOf/bindsTo: a oneshot that has exited
  # must not take the service down with it.
  systemd.services.paperless-secrets = {
    description = "Assemble Paperless runtime env from shared DB password";
    wantedBy = paperlessUnits;
    before = paperlessUnits;
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      dbpw_file=/var/lib/secrets/postgres/paperless/db-password
      out=/run/paperless/env
      install -d -m 700 /run/paperless
      if [ ! -s "$dbpw_file" ]; then
        echo "Error: $dbpw_file missing or empty (is the shared Postgres mount attached?)" >&2
        exit 1
      fi
      dbpw="$(cat "$dbpw_file")"
      # Restrictive umask so the file is never group/world readable, even
      # momentarily, before the chmod below.
      ( umask 077; printf 'PAPERLESS_DBPASS=%s\n' "$dbpw" > "$out" )
      chmod 600 "$out"
    '';
  };
}
