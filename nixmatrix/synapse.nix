# NixOS Service Configuration for Matrix Synapse
{ config, pkgs, lib, ... }:

let
  synapseClientId = "0000000000000000000SYNAPSE";

  # ---------------------------------------------------------------------------
  # Media storage on the internal Garage S3 bucket (CT 109 -> 192.168.1.132).
  #
  # Media (avatars, images, files, thumbnails) lives in object storage only:
  # local media storage is switched off, so uploads are streamed straight into
  # the bucket and the container disk never holds media.  Garage speaks the S3
  # API, so Synapse uses the s3-storage-provider plugin.
  #
  # The price is URL previews: Synapse reads url_cache files *only* from the
  # on-disk provider, so with no local provider a preview would be written to
  # S3 and then 404 forever.  Link previews are therefore disabled together
  # with local storage instead of being left silently broken.
  # Credentials are *not* kept in the repo: they are read at runtime from
  # /var/lib/secrets/matrix/s3 (see README.md).  When those two key files are
  # absent Synapse uses the plain on-disk media store only, which keeps
  # evaluation and the VM tests independent of Garage.
  # ---------------------------------------------------------------------------
  s3Endpoint = "http://192.168.1.132:3900";
  s3Bucket = "synapse";
  s3Region = "garage";
  s3SecretsDir = "/var/lib/secrets/matrix/s3";
  mediaStorePath = "/var/lib/matrix-synapse/media_store";
  s3MediaProvider = pkgs.matrix-synapse-unwrapped.plugins.matrix-synapse-s3-storage-provider;
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
# S3 is the only media backend.  url_cache (link previews) can only be read
# back from the on-disk provider, so previewing is turned off with it.
enable_local_media_storage: false
url_preview_enabled: false
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

  # One-time migration of the existing on-disk media store into Garage.
  #
  # It runs *before* Synapse (so no upload can slip through during the copy),
  # uploads every local and remote media object plus its thumbnails, deletes
  # the local copies and drops a marker so it never repeats.  Failures are
  # non-fatal on purpose: Synapse still starts and the next start retries.
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

      MEDIA_STORE=${mediaStorePath}
      DONE_MARKER=/var/lib/matrix-synapse/.s3-media-migrated
      WORK_DIR=/var/lib/matrix-synapse/s3-migration
      CRED_ENV=$WORK_DIR/credentials.env

      if [ ! -d "$MEDIA_STORE" ]; then
        echo "No local media store at $MEDIA_STORE, nothing to migrate."
        exit 0
      fi
      if [ ! -s "$CRED_ENV" ]; then
        echo "S3 credentials not configured, skipping media migration."
        exit 0
      fi
      if [ -e "$DONE_MARKER" ]; then
        echo "Media store already migrated ($DONE_MARKER exists)."
        exit 0
      fi

      # s3_media_upload keeps its sqlite cache in the working directory.
      install -d -m 750 "$WORK_DIR"
      set -a
      . "$CRED_ENV"
      set +a
      cd "$WORK_DIR"

      # 1s = "everything created more than a second ago", i.e. the whole store.
      # The DB credentials come from the generated runtime config.
      ${s3MediaProvider}/bin/s3_media_upload --no-progress update "$MEDIA_STORE" 1s \
        --homeserver-config-path /var/lib/matrix-synapse/secrets.yaml

      ${s3MediaProvider}/bin/s3_media_upload --no-progress upload "$MEDIA_STORE" "$S3_BUCKET" \
        --endpoint-url "$S3_ENDPOINT" --delete

      touch "$DONE_MARKER"
      chown matrix-synapse:matrix-synapse "$DONE_MARKER"
    '';
  };
}
