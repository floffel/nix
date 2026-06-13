#!/usr/bin/env bash
# Helper script to generate secure LDAP configuration files for Postfix and Dovecot
# Usage: ./setup-mail-secrets.sh <KANIDM_LDAP_API_TOKEN>

TOKEN="$1"
if [ -z "$TOKEN" ]; then
  echo "Error: KANIDM_LDAP_API_TOKEN is required."
  echo "Usage: $0 <KANIDM_LDAP_API_TOKEN>"
  exit 1
fi

DEST_DIR="/var/lib/secrets/mail"
mkdir -p "$DEST_DIR/postfix" "$DEST_DIR/dovecot"

# 1. Write Dovecot LDAP password file
echo "$TOKEN" > "$DEST_DIR/dovecot/ldap-password.txt"
chmod 600 "$DEST_DIR/dovecot/ldap-password.txt"
chown -R 97:97 "$DEST_DIR/dovecot" # 97 is standard dovecot uid/gid on NixOS (verify with id dovecot)

# 2. Write Postfix LDAP query configuration files

# ldap-recipients.cf: Validates active mailboxes
cat <<EOF > "$DEST_DIR/postfix/ldap-recipients.cf"
server_host = ldaps://ldap:636
search_base = ou=people,dc=minnecker,dc=com
query_filter = (&(mail=%s)(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))
result_attribute = mail
bind = yes
bind_dn = dn=token
bind_pw = $TOKEN
version = 3
tls_require_cert = no
EOF

# ldap-aliases.cf: Resolves aliases
cat <<EOF > "$DEST_DIR/postfix/ldap-aliases.cf"
server_host = ldaps://ldap:636
search_base = ou=people,dc=minnecker,dc=com
query_filter = (&(mail=%s)(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))
result_attribute = uid
result_format = %s@minnecker.com
bind = yes
bind_dn = dn=token
bind_pw = $TOKEN
version = 3
tls_require_cert = no
EOF

# ldap-senders.cf: Validates who is authorized to send from a given envelope address
cat <<EOF > "$DEST_DIR/postfix/ldap-senders.cf"
server_host = ldaps://ldap:636
search_base = ou=people,dc=minnecker,dc=com
query_filter = (&(mail=%s)(memberof=cn=mail_users,ou=groups,dc=minnecker,dc=com))
result_attribute = uid
bind = yes
bind_dn = dn=token
bind_pw = $TOKEN
version = 3
tls_require_cert = no
EOF

# ldap-domains.cf: Dynamically validates virtual mailbox domains
cat <<EOF > "$DEST_DIR/postfix/ldap-domains.cf"
server_host = ldaps://ldap:636
search_base = ou=people,dc=minnecker,dc=com
query_filter = (mail=*@%s)
result_attribute = mail
bind = yes
bind_dn = dn=token
bind_pw = $TOKEN
version = 3
tls_require_cert = no
EOF

# Set secure permissions for Postfix config files
chmod 600 "$DEST_DIR/postfix"/*.cf
chown -R 98:98 "$DEST_DIR/postfix" # 98 is standard postfix uid/gid on NixOS (verify with id postfix)

echo "Success: Secure LDAP configuration files written to $DEST_DIR"
