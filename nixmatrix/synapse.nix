# NixOS Service Configuration for Matrix Synapse
{ config, pkgs, lib, ... }:

let
  synapseClientId = "0000000000000000000SYNAPSE";
in
{
  services.matrix-synapse = {
    enable = true;

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
    after = [ "matrix-authentication-service.service" "matrix-synapse-secrets-config.service" ];
    wants = [ "matrix-authentication-service.service" "matrix-synapse-secrets-config.service" ];
    restartTriggers = [
      config.systemd.services.matrix-synapse-secrets-config.script
    ];
  };

  systemd.services.matrix-synapse-secrets-config = {
    description = "Generate Matrix Synapse runtime config (database + OAuth delegation)";
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

      install -d -m 755 -o matrix-synapse -g matrix-synapse "$(dirname "$OUT")"

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
EOF
      chown matrix-synapse:matrix-synapse "$OUT"
      chmod 600 "$OUT"
    '';
  };
}