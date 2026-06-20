# NixOS Service Configuration for Kanidm Identity Management
{ config, pkgs, lib, ... }:

{
  services.kanidm = {
    # Use the build of kanidm that ships the kanidm-provision tooling used by the
    # declarative provisioning hook below.
    package = pkgs.kanidm.withSecretProvisioning;

    server = {
      enable = true;
      settings = {
        # Bind the HTTP/HTTPS/SSO server to port 8443
        bindaddress = "0.0.0.0:8443";

        # Bind the read-only LDAP compatibility server to port 636
        ldapbindaddress = "0.0.0.0:636";

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
      groups = {
        # Built-in administrator group. Declared so the claimMaps below can
        # reference it (the module asserts every referenced group is declared,
        # even built-ins). Members of idm_admins act as a global fallback that
        # is granted admin in every service that supports OIDC admin claims.
        idm_admins.present = true;
        mail_users.present = true;
        forgejo_users.present = true;
        nextcloud_users.present = true;
        nextcloud_admins.present = true;
        grafana_users.present = true;
        grafana_admins.present = true;
        matrix_users.present = true;
        open_webui_users.present = true;
        open_webui_admins.present = true;
      };

      # OAuth2 / OIDC resource servers. Each non-public client reads its basic
      # client secret from the shared secrets mount; the corresponding file on
      # the consumer container is populated from `kanidm system oauth2
      # show-basic-secret <client>` once (see each service's README).
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
          basicSecretFile = "/var/lib/secrets/kanidm/oauth2-forgejo-basic-secret";
          scopeMaps = { forgejo_users = [ "openid" "email" "profile" ]; };
        };

        nextcloud = {
          displayName = "Nextcloud Cloud";
          originUrl = "https://cloud.minnecker.com/index.php/apps/user_oidc/code";
          originLanding = "https://cloud.minnecker.com/";
          basicSecretFile = "/var/lib/secrets/kanidm/oauth2-nextcloud-basic-secret";
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
          basicSecretFile = "/var/lib/secrets/kanidm/oauth2-grafana-basic-secret";
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
          basicSecretFile = "/var/lib/secrets/kanidm/oauth2-matrix-basic-secret";
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
