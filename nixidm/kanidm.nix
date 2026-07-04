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
    path = [ pkgs.curl pkgs.jq pkgs.openldap ];
    script = ''
      set -euo pipefail

      IDM_PASSWORD=$(cat /var/lib/secrets/kanidm/idm-admin-password)
      COOKIE_JAR=$(mktemp)
      trap 'rm -f "$COOKIE_JAR"' EXIT
      API="https://localhost:8443"
      TOKEN_FILE=/var/lib/secrets/mail/ldap/ldap-token
      export LDAPTLS_REQCERT=never

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
        -d '{"step":{"init2":{"username":"idm_admin","issue":"token","privileged":false}}}')
      if ! echo "$RESP" | jq -e '.state.choose' >/dev/null 2>&1; then
        echo "ERROR: auth init failed: $RESP" >&2
        exit 1
      fi

      # Auth step 2: begin password mechanism
      curl -sk -b "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d '{"step":{"begin":"password"}}' >/dev/null

      # Auth step 3: provide password, extract bearer token
      RESP=$(curl -sk -b "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d "{\"step\":{\"cred\":{\"password\":\"$IDM_PASSWORD\"}}}")
      BEARER=$(echo "$RESP" | jq -r '.state.success // empty')
      if [ -z "$BEARER" ]; then
        echo "ERROR: password auth failed: $RESP" >&2
        exit 1
      fi
      echo "Authenticated as idm_admin."

      # Ensure the mailservice service account exists (missing after DB restore).
      # The GET endpoint returns 200 + null (not 404) for missing accounts, so
      # check the body rather than the HTTP status code.
      RESP=$(curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
        "$API/v1/service_account/mailservice")
      if [ "$(echo "$RESP" | jq -r '.')" = "null" ] || [ -z "$RESP" ]; then
        echo "Creating mailservice service account..."
        curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
          -X POST "$API/v1/service_account" \
          -H "Content-Type: application/json" \
          -d '{"attrs":{"name":["mailservice"],"displayname":["Mail Service"],"entry_managed_by":["idm_admins"]}}' \
          >/dev/null
      fi

      # Grant the mailservice account read access to person PII (the `mail`
      # attribute is classified as personally identifying information in
      # Kanidm). Without membership in the builtin `idm_people_pii_read`
      # group, LDAP searches by Postfix/Dovecot match entries but they are
      # "denied - no entries were released", so every mailbox lookup fails.
      # Idempotent: only add the member if not already present.
      RESP=$(curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
        "$API/v1/group/idm_people_pii_read/_attr/member")
      if ! echo "$RESP" | jq -e 'index("mailservice@minnecker.com")' >/dev/null 2>&1; then
        echo "Adding mailservice to idm_people_pii_read..."
        curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
          -X POST "$API/v1/group/idm_people_pii_read/_attr/member" \
          -H "Content-Type: application/json" \
          -d '["mailservice@minnecker.com"]' >/dev/null
      fi

      # Reuse the existing mail_token if it is still valid. Kanidm signs API
      # tokens with key material stored in its database, so a token survives a
      # normal service restart (same DB, same keys) and only becomes invalid
      # after a DB restore/recreate. The previous unconditional destroy +
      # regenerate on every Kanidm start created a desync window: consumers on
      # nixmail (and nixnginx) hold the old token in long-lived LDAP
      # connection pools and cached config files, and the Proxmox/NAS shared
      # mount does not deliver inotify events across the network boundary, so
      # a path watcher cannot reliably push the rotated token to them. After
      # the 5-minute AUTH_TOKEN_GRACE_WINDOW elapses, searches with the now-
      # destroyed token fail with "SessionExpired". By validating the existing
      # token via the exact LDAP bind+search path the consumers use, the
      # common case (plain restart) becomes a no-op and no rotation occurs.
      EXISTING=""
      if [ -s "$TOKEN_FILE" ]; then
        EXISTING=$(cat "$TOKEN_FILE")
      fi
      if [ -n "$EXISTING" ] && \
         ldapsearch -x -H ldaps://localhost:636 -D "dn=token" -w "$EXISTING" \
           -b "dc=minnecker,dc=com" "(objectClass=account)" dn -z 1 >/dev/null 2>&1; then
        echo "Existing mail_token still valid — keeping it (no rotation)."
        TOKEN="$EXISTING"
      else
        echo "No existing mail_token or it is invalid — regenerating."

        # Destroy old tokens with label "mail_token" to avoid accumulation
        echo "Destroying old mail_token tokens..."
        RESP=$(curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
          "$API/v1/service_account/mailservice/_api_token")
        # Only iterate if the response is a JSON array (not an error string)
        if echo "$RESP" | jq -e 'type == "array"' >/dev/null 2>&1; then
          for tid in $(echo "$RESP" | jq -r '.[] | select(.label=="mail_token") | .token_id'); do
            echo "  destroying $tid"
            curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
              -X DELETE "$API/v1/service_account/mailservice/_api_token/$tid" \
              -d '[]' >/dev/null
          done
        fi

        # Generate a fresh read-only API token
        echo "Generating new mail_token..."
        HTTP_CODE=$(curl -sk -b "$COOKIE_JAR" -H "Authorization: Bearer $BEARER" \
          -X POST "$API/v1/service_account/mailservice/_api_token" \
          -H "Content-Type: application/json" \
          -d '{"label":"mail_token","expiry":null,"read_write":false,"compact":false}' \
          -o /tmp/mail-token-resp -w '%{http_code}')
        RESP=$(cat /tmp/mail-token-resp)
        rm -f /tmp/mail-token-resp
        if [ "$HTTP_CODE" != "200" ]; then
          echo "ERROR: token generation failed (HTTP $HTTP_CODE): $RESP" >&2
          exit 1
        fi
        TOKEN=$(echo "$RESP" | jq -r '.')
        if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
          echo "ERROR: token generation returned empty: $RESP" >&2
          exit 1
        fi
        # A valid JWS token starts with "eyJ" (base64 for '{"')
        if [ "''${TOKEN#eyJ}" = "$TOKEN" ]; then
          echo "ERROR: generated token is not a valid JWS: $TOKEN" >&2
          exit 1
        fi
        echo "Token generated."
      fi

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
        url "ldaps://ldap:636/dc=minnecker,dc=com?uid?sub?(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com)";
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
          originUrl = "https://monitoring.minnecker.com/login/generic_oauth";
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

        # Mail XOAUTH2 client. A single public (PKCE) OAuth2 client used by
        # ALL mail consumers: desktop/mobile clients (Thunderbird, K-9 Mail,
        # Apple Mail) AND Roundcube webmail. Users authenticate to Kanidm
        # via a browser-based authorisation code flow using their full
        # Kanidm credentials (including MFA), and receive an access token
        # that Dovecot validates via the /oauth2/openid/mail/userinfo
        # endpoint. This eliminates the need for a separate POSIX password.
        #
        # Why a single client for everything: Kanidm's userinfo endpoint is
        # per-client (the client_id is in the URL path and the token's `aud`
        # must match). Dovecot's oauth2 passdb has a single introspection_url,
        # so all tokens it validates must come from the same OAuth2 client.
        # Using separate clients for Roundcube vs desktop apps would require
        # Dovecot to validate tokens at two different userinfo endpoints,
        # which it cannot do with a single oauth2 passdb.
        #
        # enableLocalhostRedirects: RFC 8252 loopback redirect with any port
        # — desktop/mobile mail clients spin up a local HTTP server on an
        # ephemeral port to receive the authorisation code redirect.
        #
        # originUrl also includes Roundcube's HTTPS callback so the same
        # client serves the webmail login flow. Roundcube 1.6+ supports
        # PKCE (the default), so it can use a public client without a
        # client_secret — same as desktop/mobile apps.
        #
        # The scope map gates access: only members of `mail_users` receive
        # the `openid email profile` scopes. Dovecot extracts the `email`
        # field from the userinfo response as the IMAP/SMTP username.
        mail = {
          public = true;
          enableLocalhostRedirects = true;
          displayName = "Mail Server (XOAUTH2)";
          originUrl = [
            "http://localhost"
            "https://mail.minnecker.com/index.php/login/oauth"
            "https://mail.minnecker.com/login/oauth"
          ];
          originLanding = "https://mail.minnecker.com/";
          scopeMaps = { mail_users = [ "openid" "email" "profile" ]; };
        };
      };
    };
  };
}
