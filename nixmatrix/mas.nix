{ config, pkgs, lib, ... }:

let
  package = pkgs.matrix-authentication-service;
  synapseClientId = "0000000000000000000SYNAPSE";
  upstreamProviderId = "01J8QGXVJHSKAB1JFJYF2TBBDD";

  configYaml = pkgs.formats.yaml { };

  mainConfig = configYaml.generate "mas-config.yaml" {
    http = {
      public_base = "https://matrix.minnecker.com/";
      trusted_proxies = [
        "10.20.20.0/24"
        "fd01::/64"
      ];
      listeners = [
        {
          name = "web";
          resources = [
            { name = "discovery"; }
            { name = "human"; }
            { name = "oauth"; }
            { name = "compat"; }
            { name = "graphql"; }
            { name = "assets"; }
          ];
          binds = [
            {
              host = "::";
              port = 8080;
            }
          ];
        }
        {
          name = "internal";
          resources = [
            { name = "health"; }
          ];
          binds = [
            {
              host = "::";
              port = 8081;
            }
          ];
        }
      ];
    };
    database = {
      host = "nixpostgres";
      username = "mas";
      database = "mas";
    };
    matrix = {
      homeserver = "minnecker.com";
      endpoint = "http://localhost:8008";
    };
    passwords.enabled = false;
  };
in
{
  systemd.services.matrix-authentication-service = {
    description = "Matrix Authentication Service";
    after = [ "network.target" "mas-secrets-config.service" ];
    requires = [ "mas-secrets-config.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      RuntimeDirectory = "matrix-authentication-service";
      RuntimeDirectoryMode = "0755";
      ExecStartPre = pkgs.writeShellScript "mas-runtime-secrets" ''
        set -euo pipefail
        DBPW=$(cat /var/lib/secrets/postgres/matrix/mas-db-password 2>/dev/null || echo "PLACEHOLDER")
        CLIENT_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        ADMIN_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        OIDC_SECRET=$(cat /var/lib/secrets/oauth2/matrix/mas-secret 2>/dev/null || echo "PLACEHOLDER")

        cat > /run/matrix-authentication-service/secrets.yaml <<EOF
database:
  password: "$DBPW"
matrix:
  secret: "$ADMIN_TOKEN"
clients:
  - client_id: "${synapseClientId}"
    client_auth_method: "client_secret_basic"
    client_secret: "$CLIENT_SECRET"
upstream_oauth2:
  providers:
    - id: "${upstreamProviderId}"
      human_name: "Kanidm"
      issuer: "https://idm.minnecker.com/oauth2/openid/mas"
      client_id: "mas"
      token_endpoint_auth_method: "client_secret_basic"
      id_token_signed_response_alg: "ES256"
      scope: "openid profile email"
      claims_imports:
        localpart:
          action: "require"
          template: "{{ user.preferred_username | split(pat=\"@\") | first }}"
        displayname:
          action: "suggest"
          template: "{{ user.name }}"
        email:
          action: "suggest"
          template: "{{ user.email }}"
      client_secret: "$OIDC_SECRET"
EOF
        chmod 644 /run/matrix-authentication-service/secrets.yaml

        printf '%s' "$CLIENT_SECRET" > /run/matrix-authentication-service/synapse-client-secret
        printf '%s' "$ADMIN_TOKEN" > /run/matrix-authentication-service/synapse-admin-token
        chmod 644 /run/matrix-authentication-service/synapse-client-secret \
          /run/matrix-authentication-service/synapse-admin-token
      '';
      ExecStart = lib.concatStringsSep " " [
        "${lib.getExe package}" "server"
        "--config" "${mainConfig}"
        "--config" "/run/matrix-authentication-service/secrets.yaml"
        "--config" "/var/lib/matrix-authentication-service/persistent-secrets.yaml"
      ];
      Restart = "on-failure";
      RestartSec = "1s";
      StateDirectory = "matrix-authentication-service";
      StateDirectoryMode = "0700";
      WorkingDirectory = "/var/lib/matrix-authentication-service";

      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      LockPersonality = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectSystem = "strict";
      RemoveIPC = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallErrorNumber = "EPERM";
      SystemCallFilter = [
        "@system-service"
      ];
      UMask = "0077";
    };
  };

  systemd.services.mas-secrets-config = {
    description = "Generate MAS persistent secrets (encryption + signing keys)";
    wantedBy = [ "matrix-authentication-service.service" ];
    before = [ "matrix-authentication-service.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils pkgs.openssl ];
    script = ''
      set -euo pipefail

      PERSISTENT=/var/lib/matrix-authentication-service/persistent-secrets.yaml
      if [ ! -f "$PERSISTENT" ]; then
        install -d -m 755 "$(dirname "$PERSISTENT")"
        ENCRYPTION=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /var/lib/matrix-authentication-service/signing-key.pem 2>/dev/null
        chmod 600 /var/lib/matrix-authentication-service/signing-key.pem

        cat > "$PERSISTENT" <<PEOF
secrets:
  encryption: "$ENCRYPTION"
  keys:
    - kid: "01J8QQ0000000000000000000MAS"
      key_file: /var/lib/matrix-authentication-service/signing-key.pem
      alg: "RS256"
PEOF
        chmod 600 "$PERSISTENT"
      fi
    '';
  };
}