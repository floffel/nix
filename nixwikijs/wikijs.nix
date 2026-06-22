# NixOS Service Configuration for Wiki.js
{ config, pkgs, lib, ... }:

{
  services.wiki-js = {
    enable = true;

    # Configure settings matching upstream JSON/YAML keys
    settings = {
      port = 3000;
      bindIP = "0.0.0.0";
      db = {
        type = "postgres";
        host = "nixpostgres";
        port = 5432;
        user = "wikijs";
        # WIKI_DB_PASS is injected at runtime from the shared Postgres
        # secrets mount via the environmentFile assembled by
        # wikijs-secrets (see below).
        pass = "$(WIKI_DB_PASS)";
        db = "wikijs";
        ssl = false;
      };
    };

    # The runtime environment file is assembled by the wikijs-secrets unit
    # (see below) from the per-container template plus the database password
    # read from the shared Postgres secrets mount
    # (/var/lib/secrets/postgres/wikijs/db-password, provisioned on
    # nixpostgres and bind-mounted read-only here). This keeps Postgres the
    # sole writer of DB passwords.
    environmentFile = "/run/wikijs/env";
  };

  # Assemble the runtime env file on every start of wiki-js from the DB
  # password pulled from the shared Postgres secrets mount. partOf + bindsTo
  # couple this oneshot to wiki-js.service so it re-runs on every (re)start
  # (not just at boot), keeping the tmpfs env file fresh; RemainAfterExit is
  # omitted so each restart re-assembles it.
  #
  # The wiki-js module uses DynamicUser, so there is no static system user to
  # chown the file to. systemd reads EnvironmentFile as root before dropping
  # privileges, so a root-owned 0600 file is readable by the dynamic service
  # user via the manager — no chown needed.
  systemd.services.wikijs-secrets = {
    description = "Assemble Wiki.js runtime env from shared DB password";
    wantedBy = [ "wiki-js.service" ];
    before = [ "wiki-js.service" ];
    partOf = [ "wiki-js.service" ];
    bindsTo = [ "wiki-js.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      dbpw_file=/var/lib/secrets/postgres/wikijs/db-password
      out=/run/wikijs/env
      install -d -m 700 /run/wikijs
      if [ ! -s "$dbpw_file" ]; then
        echo "Error: $dbpw_file missing or empty (is the shared Postgres mount attached?)" >&2
        exit 1
      fi
      dbpw="$(cat "$dbpw_file")"
      # Write with a restrictive umask so the file is never world/group-readable,
      # even momentarily, before the chmod below.
      ( umask 077; printf 'WIKI_DB_PASS=%s\n' "$dbpw" > "$out" )
      chmod 600 "$out"
    '';
  };
}
