{ config, pkgs, lib, ... }:

{
  services.qemuGuest.enable = lib.mkForce true;

  networking.useDHCP = lib.mkForce true;
  networking.firewall.enable = lib.mkForce true;
  networking.extraHosts = ''
    127.0.0.1 nixpostgres
    127.0.0.1 nixpostgresql
    127.0.0.1 nixidm
    127.0.0.1 nixidm
    127.0.0.1 nixopenwebui
    127.0.0.1 openwebui
    127.0.0.1 forgejo
    127.0.0.1 nixforgejo
    127.0.0.1 nixmonitoring
    127.0.0.1 nixmail
    127.0.0.1 nixmatrix
    127.0.0.1 matrix
    127.0.0.1 vaultwarden
    127.0.0.1 wikijs
    127.0.0.1 jitsi
    127.0.0.1 ki
    127.0.0.1 kiellm
    127.0.0.1 nixvaultwarden
    127.0.0.1 nixwikijs
    127.0.0.1 nixjitsi
    127.0.0.1 nixnsd
    127.0.0.1 nixunbound
  '';

  nix.settings.sandbox = lib.mkDefault false;
  systemd.suppressedSystemUnits = lib.mkForce [];

  systemd.services.test-secrets = {
    description = "Create test secrets for integration tests";
    wantedBy = [ "multi-user.target" ];
    before = [
      "nginx.service" "fail2ban.service"
      "phpfpm-nextcloud.service" "phpfpm-roundcube.service"
      "postgresql.service" "kanidm.service"
      "roundcube-setup-oauth.service" "nextcloud-setup-oidc.service"
      "postgresql-password-provisioning.service"
      "grafana.service" "alloy.service"
    ];
    serviceConfig.Type = "oneshot";
    path = with pkgs; [ openssl coreutils ];
    script = ''
      mkdir -p /var/lib/secrets/ssl/minnecker.com
      mkdir -p /var/lib/secrets/ssl/substitution.art
      openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
        -keyout /var/lib/secrets/ssl/minnecker.com/key.pem \
        -out /var/lib/secrets/ssl/minnecker.com/fullchain.pem \
        -subj "/CN=*.minnecker.com" 2>/dev/null
      openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
        -keyout /var/lib/secrets/ssl/substitution.art/key.pem \
        -out /var/lib/secrets/ssl/substitution.art/fullchain.pem \
        -subj "/CN=*.substitution.art" 2>/dev/null

      THE_PASS="$(openssl rand -base64 12)"
      for role in forgejo nextcloud roundcube matrix vaultwarden wikijs; do
        role_dir="/var/lib/secrets/postgres/$role"
        mkdir -p "$role_dir"
        echo "$THE_PASS" > "$role_dir/db-password"
        chmod 600 "$role_dir/db-password"
      done

      mkdir -p /var/lib/secrets/oauth2
      for client in forgejo nextcloud grafana matrix vaultwarden wikijs; do
        client_dir="/var/lib/secrets/oauth2/$client"
        mkdir -p "$client_dir"
        openssl rand -base64 32 > "$client_dir/secret"
        chmod 600 "$client_dir/secret"
      done

      mkdir -p /var/lib/secrets/nginx
      openssl rand -base64 16 > /var/lib/secrets/nginx/nextcloud-admin-password.txt
      chmod 600 /var/lib/secrets/nginx/nextcloud-admin-password.txt

      mkdir -p /var/lib/secrets/mail/ldap
      openssl rand -base64 32 > /var/lib/secrets/mail/ldap/ldap-token
      chmod 600 /var/lib/secrets/mail/ldap/ldap-token
      touch /var/lib/secrets/mail/ldap/nginx-ldap.conf

      mkdir -p /var/lib/secrets/nixvpn
      openssl rand -base64 32 > /var/lib/secrets/nixvpn/private.key
      chmod 600 /var/lib/secrets/nixvpn/private.key

      mkdir -p /var/lib/secrets/kanidm
      openssl rand -base64 16 > /var/lib/secrets/kanidm/idm-admin-password
      chmod 600 /var/lib/secrets/kanidm/idm-admin-password

      mkdir -p /var/lib/secrets/open-webui
      touch /var/lib/secrets/open-webui/env
      chmod 600 /var/lib/secrets/open-webui/env

      mkdir -p /var/lib/secrets/matrix
      touch /var/lib/secrets/matrix/secrets.yaml
      chmod 600 /var/lib/secrets/matrix/secrets.yaml

      mkdir -p /var/lib/secrets/vaultwarden
      touch /var/lib/secrets/vaultwarden/env-template
      chmod 600 /var/lib/secrets/vaultwarden/env-template

      mkdir -p /var/lib/secrets/wikijs
      touch /var/lib/secrets/wikijs/admin-password
      chmod 600 /var/lib/secrets/wikijs/admin-password

      mkdir -p /var/lib/secrets/nsd
      echo "xw==" > /var/lib/secrets/nsd/sync.key
      chmod 600 /var/lib/secrets/nsd/sync.key

      mkdir -p /var/lib/secrets/forgejo
      openssl rand -base64 32 > /var/lib/secrets/forgejo/runner-token
      chmod 600 /var/lib/secrets/forgejo/runner-token

      mkdir -p /var/lib/nextcloud-data
      chmod 700 /var/lib/nextcloud-data

      mkdir -p /var/lib/node-exporter-textfile
      chmod 755 /var/lib/node-exporter-textfile
    '';
  };
}