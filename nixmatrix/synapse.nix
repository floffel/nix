# NixOS Service Configuration for Matrix Synapse
{ config, pkgs, lib, ... }:

let
  synapseClientId = "0000000000000000000SYNAPSE";

  # ---------------------------------------------------------------------------
  # Media storage on the internal Garage S3 bucket (CT 109 -> 192.168.1.132).
  #
  # Garage speaks the S3 API, so Synapse uses the s3-storage-provider plugin:
  # every own upload and every downloaded remote media object (plus their
  # thumbnails) is copied into the bucket, and reads fall back to the bucket
  # for anything that is no longer on disk.
  #
  # S3 can however *not* replace the local store with this plugin: Synapse
  # passes providers only the *relative* media path and writes the bytes to
  # disk only when a local provider exists (otherwise into a NamedTemporaryFile
  # whose name is never handed on), while the plugin uploads the path it
  # rebuilt as media_store_path + path.  So with
  # enable_local_media_storage: false it uploads a file that was never written
  # and every upload dies with FileNotFoundError -> HTTP 500.  That is
  # upstream issue synapse-s3-storage-provider#162 (open, unfixed as of v1.7.0,
  # see README.md).  Media storage is a mirror plus an offload here:
  #   * store_synchronous: true, so an upload is only acknowledged once the
  #     object is in Garage and the bucket is complete at all times;
  #   * a recurring timer runs the plugin's documented
  #     `s3_media_upload update ... && upload ... --delete` pair, which pushes
  #     whatever is still local into the bucket and reclaims the disk.
  # The steady state on disk is thus media from roughly the last timer
  # interval plus the link-preview cache: Synapse reads url_cache files *only*
  # from the on-disk provider and the upload script skips them by design
  # (`url_cache IS NULL`), which is why local storage also keeps URL previews
  # working instead of having to disable them.
  #
  # Credentials are *not* kept in the repo: they are read at runtime from
  # /var/lib/secrets/matrix/s3 (see README.md).  When those two key files are
  # absent neither the provider block nor the sync jobs are active, which
  # keeps evaluation and the VM tests independent of Garage.
  # ---------------------------------------------------------------------------
  s3Endpoint = "http://192.168.1.132:3900";
  s3Bucket = "synapse";
  s3Region = "garage";
  s3SecretsDir = "/var/lib/secrets/matrix/s3";
  mediaStorePath = "/var/lib/matrix-synapse/media_store";
  s3MediaProvider = pkgs.matrix-synapse-unwrapped.plugins.matrix-synapse-s3-storage-provider;

  # Shared body of both "move local media into Garage" jobs: the command pair
  # documented by the plugin.  It takes the maximum age since a media object's
  # last access, so the one-time migration passes 1s (the whole store, and
  # Synapse is not running yet) while the timer passes a margin that leaves
  # uploads still in flight alone.
  #
  # Beware the unit suffixes of s3_media_upload: they are s/h/d/m/y where *m
  # means 30-day months* and there is no minute unit ("seconds can be used to
  # implement minutes", says the script itself).  Writing 30m here would mean
  # 900 days, i.e. a job that silently offloads nothing.
  #
  # Both jobs run as matrix-synapse and read their credentials from the env
  # file written by matrix-synapse-secrets-config; without that file they are
  # no-ops, which keeps them harmless when no S3 keys are installed.
  s3MediaSync = pkgs.writeShellScript "matrix-synapse-s3-media-sync" ''
    set -euo pipefail

    MAX_AGE="$1"
    MEDIA_STORE=${mediaStorePath}
    WORK_DIR=/var/lib/matrix-synapse/s3-migration
    CRED_ENV="$WORK_DIR/credentials.env"

    if [ ! -d "$MEDIA_STORE" ]; then
      echo "No local media store at $MEDIA_STORE, nothing to sync."
      exit 0
    fi
    if [ ! -s "$CRED_ENV" ]; then
      echo "S3 credentials not configured, skipping the media sync."
      exit 0
    fi

    # s3_media_upload keeps an incremental sqlite cache in the working
    # directory; sharing it makes every run after the first one cheap.
    install -d -m 750 "$WORK_DIR"
    set -a
    . "$CRED_ENV"
    set +a
    cd "$WORK_DIR"

    # 1. note every media row of the Synapse database whose last access is
    #    older than $MAX_AGE (database credentials come from the generated
    #    runtime config; link-preview rows are skipped by the script itself)
    # 2. upload the objects that are not in the bucket yet and delete the
    #    local copies, which is what reclaims the container disk
    ${s3MediaProvider}/bin/s3_media_upload --no-progress update \
      "$MEDIA_STORE" "$MAX_AGE" \
      --homeserver-config-path /var/lib/matrix-synapse/secrets.yaml

    ${s3MediaProvider}/bin/s3_media_upload --no-progress upload \
      "$MEDIA_STORE" "$S3_BUCKET" --endpoint-url "$S3_ENDPOINT" --delete
  '';
in
{
  services.matrix-synapse = {
    enable = true;

    # Adds s3_storage_provider to Synapse's PYTHONPATH so the
    # media_storage_providers module in secrets.yaml can be imported.
    plugins = [ s3MediaProvider ];

    settings = {
      server_name = "minnecker.com";
      public_baseurl = "https://matrix.minnecker.com/";

      turn_uris = [
        "turn:turn.minnecker.com:3478?transport=udp"
        "turns:turn.minnecker.com:5349?transport=tcp"
      ];

      # MatrixRTC / LiveKit transport.  Element X's native SDK prefers the
      # authenticated /_matrix/client/v1/rtc/transports endpoint over the
      # .well-known rtc_foci, so Synapse must advertise the transport here.
      # The endpoint is only registered with msc4143_enabled.
      experimental_features = {
        msc4143_enabled = true;
      };
      matrix_rtc = {
        transports = [
          {
            type = "livekit";
            livekit_service_url = "https://livekit.minnecker.com/jwt";
          }
        ];
      };

      listeners = [
        {
          port = 8008;
          bind_addresses = [ "::" ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {
              names = [ "client" ];
              compress = true;
            }
            {
              names = [ "federation" ];
              compress = false;
            }
            # Needed for Element Call / MatrixRTC: get an OpenID token to
            # exchange with lk-jwt-service for a LiveKit JWT.
            {
              names = [ "openid" ];
            }
          ];
        }
      ];

      enable_registration = false;
    };

    extraConfigFiles = [
      "/var/lib/matrix-synapse/secrets.yaml"
    ];
  };

  systemd.services.matrix-synapse = {
    after = [
      "matrix-authentication-service.service"
      "matrix-synapse-secrets-config.service"
      "matrix-synapse-s3-media-migration.service"
    ];
    wants = [
      "matrix-authentication-service.service"
      "matrix-synapse-secrets-config.service"
      "matrix-synapse-s3-media-migration.service"
    ];
    restartTriggers = [
      config.systemd.services.matrix-synapse-secrets-config.script
    ];
  };

  systemd.services.matrix-synapse-secrets-config = {
    description = "Generate Matrix Synapse runtime config (database + OAuth delegation + S3 media)";
    wantedBy = [ "matrix-synapse.service" ];
    before = [ "matrix-synapse.service" ];
    after = [ "mas-secrets-config.service" ];
    wants = [ "mas-secrets-config.service" ];
    partOf = [ "matrix-synapse.service" ];
    bindsTo = [ "matrix-synapse.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail

      OUT=/var/lib/matrix-synapse/secrets.yaml

      DBPW=$(cat /var/lib/secrets/postgres/matrix/db-password 2>/dev/null || echo "PLACEHOLDER")
      MAS_CLIENT_SECRET=$(cat /var/lib/matrix-authentication-service/client-secret 2>/dev/null || echo "PLACEHOLDER")
      MAS_ADMIN_TOKEN=$(cat /var/lib/matrix-authentication-service/admin-token 2>/dev/null || echo "PLACEHOLDER")
      TURN_SECRET=$(cat /var/lib/secrets/coturn/shared-secret 2>/dev/null || echo "PLACEHOLDER")
      S3_ACCESS_KEY=$(cat ${s3SecretsDir}/access-key 2>/dev/null || echo "")
      S3_SECRET_KEY=$(cat ${s3SecretsDir}/secret-key 2>/dev/null || echo "")

      install -d -m 755 -o matrix-synapse -g matrix-synapse "$(dirname "$OUT")"

      # Media goes to Garage as soon as both key files exist.  Without them we
      # keep the local media store (and the migration unit stays a no-op).
      S3_BLOCK=""
      if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ]; then
        S3_BLOCK=$(cat <<EOF
# Every media write is mirrored into Garage before it is acknowledged, and
# reads fall back to the bucket.  The local store stays enabled on purpose:
# this provider uploads the file it just wrote to media_store, so removing it
# breaks uploads entirely (see the comment at the top of this file).  The
# recurring matrix-synapse-s3-media-cleanup timer moves local copies over.
media_storage_providers:
  - module: s3_storage_provider.S3StorageProviderBackend
    store_local: true
    store_remote: true
    store_synchronous: true
    config:
      bucket: "${s3Bucket}"
      region_name: "${s3Region}"
      endpoint_url: "${s3Endpoint}"
      access_key_id: "$S3_ACCESS_KEY"
      secret_access_key: "$S3_SECRET_KEY"
EOF
      )
      fi

      cat > "$OUT" <<EOF
database:
  name: "psycopg2"
  args:
    user: "matrix"
    database: "matrix"
    host: "nixpostgres"
    port: 5432
    password: "$DBPW"
  allow_unsafe_locale: true
matrix_authentication_service:
  enabled: true
  issuer: "https://matrix.minnecker.com/"
  client_id: "${synapseClientId}"
  client_auth_method: "client_secret_basic"
  client_secret: "$MAS_CLIENT_SECRET"
  secret: "$MAS_ADMIN_TOKEN"
  account_management_url: "https://matrix.minnecker.com/account"
turn_shared_secret: "$TURN_SECRET"
$S3_BLOCK
EOF
      chown matrix-synapse:matrix-synapse "$OUT"
      chmod 600 "$OUT"

      # Credentials for the one-time media migration, handed to the
      # unprivileged matrix-synapse-s3-media-migration unit.  The key files
      # themselves stay 0600/root-owned like every other secret in this repo,
      # so they are never read by the service user directly.
      WORK_DIR=/var/lib/matrix-synapse/s3-migration
      install -d -m 750 -o matrix-synapse -g matrix-synapse "$WORK_DIR"
      if [ -n "$S3_BLOCK" ]; then
        cat > "$WORK_DIR/credentials.env" <<EOF
AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
AWS_DEFAULT_REGION="${s3Region}"
AWS_REGION="${s3Region}"
S3_BUCKET="${s3Bucket}"
S3_ENDPOINT="${s3Endpoint}"
EOF
        chown matrix-synapse:matrix-synapse "$WORK_DIR/credentials.env"
        chmod 600 "$WORK_DIR/credentials.env"
      fi
    '';
  };

  # One-time migration of the media store that existed before the bucket was
  # wired up.
  #
  # It runs *before* Synapse (so no upload can slip through during the copy),
  # uploads every local and remote media object plus its thumbnails, deletes
  # the local copies and drops a marker so it never repeats.  From then on the
  # recurring matrix-synapse-s3-media-cleanup timer does the same job
  # incrementally.  Failures are non-fatal on purpose: Synapse still starts
  # and the next start retries.
  systemd.services.matrix-synapse-s3-media-migration = {
    description = "Migrate the Synapse media store into the Garage S3 bucket";
    wantedBy = [ "matrix-synapse.service" ];
    before = [ "matrix-synapse.service" ];
    after = [ "matrix-synapse-secrets-config.service" ];
    wants = [ "matrix-synapse-secrets-config.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "matrix-synapse";
      Group = "matrix-synapse";
      # The upload can take a long time on a full media store.
      TimeoutStartSec = 0;
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail

      DONE_MARKER=/var/lib/matrix-synapse/.s3-media-migrated
      if [ -e "$DONE_MARKER" ]; then
        echo "Media store already migrated ($DONE_MARKER exists)."
        exit 0
      fi

      # 1s = "everything accessed more than a second ago", i.e. the whole store.
      ${s3MediaSync} 1s

      touch "$DONE_MARKER"
      chown matrix-synapse:matrix-synapse "$DONE_MARKER"
    '';
  };

  # Offload job for the media that arrives after the migration.
  #
  # Uploads are mirrored into Garage synchronously, so the bucket is complete
  # the moment an upload succeeds; this unit exists to hand the disk space
  # back and to catch anything the plugin could not upload (Garage down, for
  # instance).  Anything still on disk is by definition also in the bucket,
  # so a failed run only delays reclaiming space.
  systemd.services.matrix-synapse-s3-media-cleanup = {
    description = "Move remaining local Synapse media into the Garage S3 bucket";
    # Deliberately not Wanted=/PartOf= matrix-synapse: the config service it
    # would need is bound to Synapse with BindsTo=/PartOf=, so pulling it in
    # from a timer could stop Synapse when the timer's unit is stopped.
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "matrix-synapse";
      Group = "matrix-synapse";
      TimeoutStartSec = 0;
    };
    path = [ pkgs.coreutils ];
    # 1800s (30 min) since the last access is far beyond the lifetime of an
    # upload or download in flight, so a file is never deleted out from under a
    # running request.  Not 30m: that would mean 30 *months*, see above.
    script = ''
      exec ${s3MediaSync} 1800s
    '';
  };

  systemd.timers.matrix-synapse-s3-media-cleanup = {
    description = "Periodically move local Synapse media into the Garage S3 bucket";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15m";
      OnUnitActiveSec = "30m";
    };
  };
}
