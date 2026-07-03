# NixOS Service Configuration for Kanidm Identity Management
{ config, pkgs, lib, ... }:

{
  # Auto-provision the per-client OAuth2 basic secret files on the shared
  # rw mount if they are missing. Runs once before kanidm.service so the
  # files exist before systemd sets up the kanidm unit's read-only bind
  # mounts derived from basicSecretFile (which resolve at ExecStartPre /
  # namespace-setup time and abort the unit with 226/NAMESPACE if a source
  # path is absent on first boot).
  systemd.services.kanidm-oauth2-secrets = {
    description = "Provision OAuth2 client basic secret files";
    wantedBy = [ "kanidm.service" ];
    before = [ "kanidm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.openssl ];
    script = ''
      for c in forgejo nextcloud grafana matrix; do
        d=/var/lib/secrets/oauth2/$c
        mkdir -p "$d"
        if [ ! -s "$d/secret" ]; then
          printf '%s' "$(openssl rand -hex 32)" > "$d/secret"
        fi
        chmod 600 "$d/secret"
      done
    '';
  };

  # Auto-generate the mail LDAP API token on every Kanidm (re)start and
  # write it — plus the pre-rendered nginx ldap.conf — to the shared mail
  # secrets mount.  Dovecot, Postfix (on nixmail) and nginx-auth-ldap (on
  # nixnginx) all bind with `dn=token` using this JWS token; without it
  # every mail login fails with "Temporary authentication failure".
  #
  # Kanidm signs API tokens with key material stored in its database.  When
  # the DB is restored or recreated the old keys vanish and every
  # previously-issued token becomes invalid (KP0022KeyObjectJwsNotAssociated).
  # Regenerating on every Kanidm start guarantees consumers always have a
  # token signed by the current key set.  Old tokens with the same label are
  # destroyed first to avoid accumulating stale entries.
  #
  # The script authenticates via the REST API (curl + jq) using the idm_admin
  # password from the shared kanidm secrets mount.  It also creates the
  # `mailservice` service account if it is missing (e.g. after a DB restore).
  systemd.services.kanidm-mail-token = {
    description = "Generate mail LDAP API token and consumer configs";
    wantedBy = [ "kanidm.service" ];
    after = [ "kanidm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.curl pkgs.jq ];
    script = ''
      set -euo pipefail

      IDM_PASSWORD=$(cat /var/lib/secrets/kanidm/idm-admin-password)
      COOKIE_JAR=$(mktemp)
      trap 'rm -f "$COOKIE_JAR"' EXIT
      API="https://localhost:8443"

      # Wait for Kanidm to be ready
      echo "Waiting for Kanidm to be ready..."
      for i in $(seq 1 30); do
        if curl -sk "$API/v1/health/live" >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done

      # Auth step 1: initialise session as idm_admin (issue = Token)
      RESP=$(curl -sk -c "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d '{"step":{"Init2":{"username":"idm_admin","issue":"Token","privileged":false}}}')
      if ! echo "$RESP" | jq -e '.state.Choose' >/dev/null 2>&1; then
        echo "ERROR: auth init failed: $RESP" >&2
        exit 1
      fi

      # Auth step 2: begin password mechanism
      curl -sk -b "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d '{"step":{"Begin":"Password"}}' >/dev/null

      # Auth step 3: provide password, extract bearer token
      RESP=$(curl -sk -b "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d "{\"step\":{\"Cred\":{\"Password\":\"$IDM_PASSWORD\"}}}")
      BEARER=$(echo "$RESP" | jq -r '.state.Success // empty')
      if [ -z "$BEARER" ]; then
        echo "ERROR: password auth failed: $RESP" >&2
        exit 1
      fi
      echo "Authenticated as idm_admin."

      # Ensure the mailservice service account exists (missing after DB restore)
      HTTP_CODE=$(curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
        "$API/v1/service_account/mailservice" -o /dev/null -w '%{http_code}')
      if [ "$HTTP_CODE" = "404" ]; then
        echo "Creating mailservice service account..."
        curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
          -X POST "$API/v1/service_account" \
          -H "Content-Type: application/json" \
          -d '{"attrs":{"name":["mailservice"],"displayname":["Mail Service"],"entry_managed_by":["idm_admins"]}}' \
          >/dev/null
      fi

      # Destroy old tokens with label "mail_token" to avoid accumulation
      echo "Destroying old mail_token tokens..."
      TOKENS=$(curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
        "$API/v1/service_account/mailservice/_api_token")
      for tid in $(echo "$TOKENS" | jq -r '.[] | select(.label=="mail_token") | .token_id'); do
        echo "  destroying $tid"
        curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
          -X DELETE "$API/v1/service_account/mailservice/_api_token/$tid" \
          -d '[]' >/dev/null
      done

      # Generate a fresh read-only API token
      echo "Generating new mail_token..."
      RESP=$(curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
        -X POST "$API/v1/service_account/mailservice/_api_token" \
        -H "Content-Type: application/json" \
        -d '{"label":"mail_token","expiry":null,"read_write":false,"compact":false}')
      TOKEN=$(echo "$RESP" | jq -r '.')
      if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        echo "ERROR: token generation failed: $RESP" >&2
        exit 1
      fi
      echo "Token generated."

      # Write the raw token (consumed by nixmail's mail-ldap-config service).
      # Lives in the ldap/ subdir of the shared mail mount, which nixidm and
      # nixnginx mount in isolation (ro/rw) so they never see DKIM keys or
      # Dovecot/Postfix configs that live alongside on nixmail's full mount.
      mkdir -p /var/lib/secrets/mail/ldap
      printf '%s' "$TOKEN" > /var/lib/secrets/mail/ldap/ldap-token
      chmod 600 /var/lib/secrets/mail/ldap/ldap-token

      # Write the pre-rendered nginx ldap.conf (consumed directly by nixnginx)
      cat > /var/lib/secrets/mail/ldap/nginx-ldap.conf <<EOF
      ldap_server mail_users {
        url "ldaps://ldap:636/ou=people,dc=minnecker,dc=com?uid?sub?(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com)";
        binddn "dn=token";
        binddn_passwd "$TOKEN";
        require valid_user;
      }
      EOF
      chmod 600 /var/lib/secrets/mail/ldap/nginx-ldap.conf

      echo "Mail LDAP token and nginx ldap.conf written to shared mount."
    '';
  };

  services.kanidm = {
    # Use the build of kanidm that ships the kanidm-provision tooling used by the
    # declarative provisioning hook below. The versioned package is required
    # (the unversioned `kanidm` alias has been removed from nixpkgs).
    package = pkgs.kanidm_1_10.withSecretProvisioning;

    server = {
      enable = true;
      settings = {
        # Bind the HTTP/HTTPS/SSO server to port 8443. [::] dual-stacks on
        # Linux, covering both IPv4 and IPv6 (hosts.nix maps the short names
        # to both 10.20.20.15 and fd01::15, so IPv6 must be served too).
        bindaddress = "[::]:8443";

        # Bind the read-only LDAP compatibility server to port 636 (dual-stack).
        ldapbindaddress = "[::]:636";

        # The domain and origin of the identity manager
        domain = "minnecker.com";
        origin = "https://idm.minnecker.com";

        # Path to TLS certificates (needed for secure communication)
        tls_chain = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        tls_key = "/var/lib/secrets/ssl/minnecker.com/key.pem";

        role = "WriteReplica";
      };
    };

    # Declarative pre-provisioning of the access-control groups and OAuth2/OIDC
    # resource servers consumed by every downstream service. The kanidm module
    # runs this as an ExecStartPost hook on kanidm.service, so the directory is
    # reconciled to match this state on every (re)start. Person accounts are
    # intentionally not declared here and are managed via the Kanidm CLI/Web UI.
    provision = {
      enable = true;

      # Reuse the recovered idm_admin password instead of regenerating it on
      # every restart. Written once via `kanidmd recover-account idm_admin` and
      # stored on the shared secrets mount (see root README.md).
      idmAdminPasswordFile = "/var/lib/secrets/kanidm/idm-admin-password";

      # The provisioning hook polls this URL before applying state; it points
      # at the local server bound above.
      instanceUrl = "https://localhost:8443";
      acceptInvalidCerts = true;

      # Access-control groups. Membership is enforced from the persons side
      # (persons.<name>.groups), so these are left empty here and only declare
      # that the groups must exist. Downstream services gate authorization on
      # (memberof=cn=<group>,...) via LDAP or via oauth2 scope maps below.
      #
      # overwriteMembers = false: with the default (true) kanidm-provision
      # issues DELETE /v1/group/<name>/_attr/member to reconcile an empty
      # member list, which 404s ("nomatchingentries") on a freshly created
      # group that has never had a member attribute and aborts the provision
      # hook. Append-mode treats an empty list as a no-op.
      groups = {
        # Built-in administrator group. Declared so the claimMaps below can
        # reference it (the module asserts every referenced group is declared,
        # even built-ins). Members of idm_admins act as a global fallback that
        # is granted admin in every service that supports OIDC admin claims.
        idm_admins.present = true;
        idm_admins.overwriteMembers = false;
        mail_users.present = true;
        mail_users.overwriteMembers = false;
        forgejo_users.present = true;
        forgejo_users.overwriteMembers = false;
        nextcloud_users.present = true;
        nextcloud_users.overwriteMembers = false;
        nextcloud_admins.present = true;
        nextcloud_admins.overwriteMembers = false;
        grafana_users.present = true;
        grafana_users.overwriteMembers = false;
        grafana_admins.present = true;
        grafana_admins.overwriteMembers = false;
        matrix_users.present = true;
        matrix_users.overwriteMembers = false;
        open_webui_users.present = true;
        open_webui_users.overwriteMembers = false;
        open_webui_admins.present = true;
        open_webui_admins.overwriteMembers = false;
      };

      # OAuth2 / OIDC resource servers. Each non-public client reads its basic
      # client secret from a per-client directory on the shared secrets mount
      # (`/var/lib/secrets/oauth2/<client>/secret`). The same file is bind-mounted
      # (read-only) into the consuming container at the same path, so Kanidm and
      # the consumer always read the identical secret and can never drift — no
      # manual copy/sync step is needed. Kanidm's provisioning hook is the sole
      # writer (the mount is read-write on nixidm, read-only on consumers).
      #
      # Admin notes per upstream capability:
      #  * grafana, nextcloud, open-webui support OIDC-driven admin via a
      #    claim (groups claim value "admin" / roles claim value "admin").
      #  * forgejo and matrix-synapse have NO OIDC admin mapping upstream;
      #    admins must be promoted manually in the app. No *_admins group is
      #    declared for them since it would serve no purpose.
      systems.oauth2 = {
        forgejo = {
          displayName = "Forgejo Git";
          originUrl = "https://git.minnecker.com/user/oauth2/kanidm/callback";
          originLanding = "https://git.minnecker.com/";
          basicSecretFile = "/var/lib/secrets/oauth2/forgejo/secret";
          scopeMaps = { forgejo_users = [ "openid" "email" "profile" ]; };
        };

        nextcloud = {
          displayName = "Nextcloud Cloud";
          # Nextcloud's user_oidc builds the redirect_uri via its URL
          # generator, which omits index.php when pretty URLs are active
          # (https://cloud.minnecker.com/apps/user_oidc/code) but includes
          # it otherwise (.../index.php/apps/user_oidc/code). Kanidm
          # requires an exact match, so both forms are declared.
          originUrl = [
            "https://cloud.minnecker.com/apps/user_oidc/code"
            "https://cloud.minnecker.com/index.php/apps/user_oidc/code"
          ];
          originLanding = "https://cloud.minnecker.com/";
          basicSecretFile = "/var/lib/secrets/oauth2/nextcloud/secret";
          # user_oidc maps a `groups` claim onto local Nextcloud groups; a
          # claim value of "admin" grants server admin. The groups_name scope
          # also flows regular group membership through.
          scopeMaps = {
            nextcloud_users = [ "openid" "email" "profile" "groups_name" ];
          };
          claimMaps.groups = {
            joinType = "array";
            valuesByGroup = {
              nextcloud_admins = [ "admin" ];
              idm_admins = [ "admin" ];
            };
          };
        };

        grafana = {
          displayName = "Grafana Monitoring";
          originUrl = "https://monitoring.minnecker.com/generic_oauth/callback";
          originLanding = "https://monitoring.minnecker.com/";
          basicSecretFile = "/var/lib/secrets/oauth2/grafana/secret";
          # Grafana's role_attribute_path = contains(groups, 'admin') && 'Admin'
          # || 'Viewer' reads the `groups` claim for an "admin" value.
          scopeMaps = {
            grafana_users = [ "openid" "email" "profile" "groups_name" ];
          };
          claimMaps.groups = {
            joinType = "array";
            valuesByGroup = {
              grafana_admins = [ "admin" ];
              idm_admins = [ "admin" ];
            };
          };
        };

        matrix = {
          displayName = "Matrix Synapse";
          originUrl = "https://matrix.minnecker.com/_synapse/client/oauth2/callback";
          originLanding = "https://matrix.minnecker.com/";
          basicSecretFile = "/var/lib/secrets/oauth2/matrix/secret";
          scopeMaps = { matrix_users = [ "openid" "email" "profile" ]; };
        };

        # Open WebUI uses PKCE (no shared basic secret); the client is public
        # and the consumer only needs the client id ("open-webui"). Admin is
        # driven by a `roles` claim: value "admin" -> Open WebUI admin role,
        # value "user" -> regular login (see OAUTH_ADMIN_ROLES/OAUTH_ALLOWED_ROLES
        # on the consumer side).
        open-webui = {
          public = true;
          displayName = "Open WebUI";
          originUrl = "https://ai.minnecker.com/oauth/oidc/callback";
          originLanding = "https://ai.minnecker.com/";
          scopeMaps = { open_webui_users = [ "openid" "email" "profile" ]; };
          claimMaps.roles = {
            joinType = "array";
            valuesByGroup = {
              open_webui_users = [ "user" ];
              open_webui_admins = [ "admin" ];
              idm_admins = [ "admin" ];
            };
          };
        };
      };
    };
  };
}
