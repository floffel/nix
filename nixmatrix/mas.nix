{ config, pkgs, lib, ... }:

let
  synapseClientId = "0000000000000000000SYNAPSE";
  upstreamProviderId = "01J8QGXVJHSKAB1JFJYF2TBBDD";
in
{
  services.matrix-authentication-service = {
    enable = true;

    settings = {
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
        uri = lib.mkForce "postgresql://mas@nixpostgres/mas";
      };

      matrix = {
        homeserver = "minnecker.com";
        endpoint = "http://localhost:8008";
      };

      passwords.enabled = false;

      upstream_oauth2.providers = [
        {
          id = upstreamProviderId;
          human_name = "Kanidm";
          issuer = "https://idm.minnecker.com/oauth2/openid/mas";
          client_id = "mas";
          scope = "openid profile email";
          claims_imports = {
            localpart = {
              action = "require";
              template = "{{ user.preferred_username }}";
            };
            displayname = {
              action = "suggest";
              template = "{{ user.name }}";
            };
            email = {
              action = "suggest";
              template = "{{ user.email }}";
            };
          };
        }
      ];

      clients = [
        {
          client_id = synapseClientId;
          client_auth_method = "client_secret_basic";
        }
      ];
    };

    extraConfigFiles = [
      "/run/matrix-authentication-service/secrets.yaml"
    ];
  };

  systemd.services.mas-secrets-config = {
    description = "Generate MAS runtime secrets (DB password, shared secrets, OIDC client secret)";
    wantedBy = [ "matrix-authentication-service.service" ];
    before = [ "matrix-authentication-service.service" ];
    partOf = [ "matrix-authentication-service.service" ];
    bindsTo = [ "matrix-authentication-service.service" ];
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "matrix-authentication-service";
      RuntimeDirectoryMode = "0755";
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail

      DBPW=$(cat /var/lib/secrets/postgres/mas/db-password 2>/dev/null || echo "PLACEHOLDER")
      CLIENT_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
      ADMIN_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
      OIDC_SECRET=$(cat /var/lib/secrets/oauth2/mas/secret 2>/dev/null || echo "PLACEHOLDER")

      cat > /run/matrix-authentication-service/secrets.yaml <<EOF
database:
  password: "$DBPW"
matrix:
  secret: "$ADMIN_TOKEN"
clients:
  - client_id: "${synapseClientId}"
    client_secret: "$CLIENT_SECRET"
upstream_oauth2:
  providers:
    - id: "${upstreamProviderId}"
      client_secret: "$OIDC_SECRET"
EOF
      chmod 644 /run/matrix-authentication-service/secrets.yaml

      printf '%s' "$CLIENT_SECRET" > /run/matrix-authentication-service/synapse-client-secret
      printf '%s' "$ADMIN_TOKEN" > /run/matrix-authentication-service/synapse-admin-token
      chmod 644 /run/matrix-authentication-service/synapse-client-secret \
        /run/matrix-authentication-service/synapse-admin-token
    '';
  };
}