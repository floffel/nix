# Round-trip mail test node: runs the real Kanidm (nixidm) identity
# provider and the real mail stack (nixmail: Postfix + Dovecot + Rspamd)
# on a single machine, wired through loopback as the shared secrets mount
# and the host table (hosts.nix / test-helpers map `ldap`, `nixidm`, ... to
# 127.0.0.1).
#
# This is drastically more realistic than vm-nixmail (which only checks
# unit files): here Postfix and Dovecot actually talk LDAP to a live
# Kanidm, Rspamd runs behind the milter, and a real SMTP submission +
# IMAP login + mail delivery round trip is exercised end to end.
{ config, pkgs, lib, ... }:

{
  imports = [
    ../nixmail/nixmail.nix
    ../nixidm/kanidm.nix
    ./test-helpers.nix
  ];

  networking.hostName = "nixmail";

  # The test VM has no upstream DNS, so postfix's smtpd_helo_restrictions
  # (reject_unknown_hostname, reject_non_fqdn_hostname) would tempfail the
  # test client's EHLO. Connections originate from loopback (permitted by
  # mynetworks), so allow loopback through the HELO stage only. The
  # RECIPIENT restrictions under test are untouched — the open-relay and
  # unknown-recipient assertions still exercise the production config.
  services.postfix.settings.main.smtpd_helo_restrictions = lib.mkForce "permit_mynetworks";

  # Kanidm provisioning: the mail stack requires a person with a `mail`
  # attribute and membership in `mail_users` (see nixmail/nixmail.nix).
  # The Kanidm provision hook (ExecStartPost on kanidm.service) creates
  # groups + oauth2 clients; people are added here as test fixtures.
  services.kanidm.provision.persons = {
    testuser = {
      displayName = "Test User";
      mailAddresses = [ "testuser@minnecker.com" ];
      groups = [ "mail_users" ];
    };
    # Surrogate for the operator-managed quarantine@ alias: a recipient the
    # routing sieve can file into the Quarantine mailbox (loop-guard test).
    quarantine = {
      displayName = "Quarantine Mailbox";
      mailAddresses = [ "quarantine@minnecker.com" ];
      groups = [ "mail_users" ];
    };
  };

  # nixmail.nix now provides the rspamd_proxy milter worker itself (S0), so
  # nothing extra is needed here — it binds 127.0.0.1:11332 with a self-scan
  # upstream, which is what the roundtrip test exercised previously.

  # A POSIX password is needed by the PLAIN/LOGIN path: dovecot's LDAP
  # passdb binds as the found user DN to verify the password, and Kanidm
  # only exposes POSIX passwords (not the primary MFA credential) over
  # LDAP. kanidm-provision cannot set credentials, so set it via the
  # REST API after the provision hook has created the person.
  systemd.services.test-mail-set-password = {
    description = "Set POSIX password for round-trip test user";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" "kanidm-mail-token.service" ];
    before = [ "dovecot.service" "postfix.service" ];
    serviceConfig = {
      Type = "oneshot";
      # So the test driver can `wait_for_unit` and then safely rely on the
      # credential being present.
      RemainAfterExit = true;
    };
    path = with pkgs; [ curl jq coreutils ];
    script = ''
      set -euo pipefail

      IDM_PASSWORD=$(cat /var/lib/secrets/kanidm/idm-admin-password)
      COOKIE_JAR=$(mktemp)
      trap 'rm -f "$COOKIE_JAR"' EXIT
      API="https://localhost:8443"

      # Wait for Kanidm to be ready (provision hook has run)
      echo "Waiting for Kanidm to be ready..."
      for i in $(seq 1 60); do
        if curl -sk "$API/v1/health/live" >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done

      # 1. init session as idm_admin
      RESP=$(curl -sk -c "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d '{"step":{"init2":{"username":"idm_admin","issue":"token","privileged":false}}}')
      if ! echo "$RESP" | jq -e '.state.choose' >/dev/null 2>&1; then
        echo "ERROR: auth init failed: $RESP" >&2
        exit 1
      fi

      # 2. begin password mechanism
      curl -sk -b "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d '{"step":{"begin":"password"}}' >/dev/null

      # 3. provide password, extract bearer token
      RESP=$(curl -sk -b "$COOKIE_JAR" -X POST "$API/v1/auth" \
        -H "Content-Type: application/json" \
        -d "{\"step\":{\"cred\":{\"password\":\"$IDM_PASSWORD\"}}}")
      BEARER=$(echo "$RESP" | jq -r '.state.success // empty')
      if [ -z "$BEARER" ]; then
        echo "ERROR: password auth failed: $RESP" >&2
        exit 1
      fi

      # Wait for the provisioned person to exist, then set its POSIX
      # password (this is `kanidm person posix set-password` over REST).
      for i in $(seq 1 60); do
        RESP=$(curl -sk -H "Authorization: Bearer $BEARER" \
          "$API/v1/person/testuser@minnecker.com")
        if [ "$(echo "$RESP" | jq -r '.')" = "null" ] || [ -z "$RESP" ]; then
          sleep 2
        else
          break
        fi
      done
      curl -sk -H "Authorization: Bearer $BEARER" \
        -X PUT "$API/v1/person/testuser@minnecker.com/_unix/_credential" \
        -H "Content-Type: application/json" \
        -d '{"value":"MailTestPass.123"}' >/dev/null
      echo "POSIX password set for testuser@minnecker.com."
    '';
  };

  # The NixOS dovecot2 module names its unit `dovecot`. Serialize the mail
  # stack behind kanidm-mail-token: mail-ldap-config renders configs from
  # the token file, so dovecot/postfix must start only after the real
  # token has been written (test-helpers seeds a placeholder).
  systemd.services.dovecot.after = [ "kanidm-mail-token.service" "mail-ldap-config.service" ];
  systemd.services.postfix.after = [ "kanidm-mail-token.service" "mail-ldap-config.service" ];

  environment.systemPackages = with pkgs; [ curl jq python3 openldap ];
}