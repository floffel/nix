# Pull request checklist

- [x] Update hosts.nix with new IPv4/IPv6 addresses and nameservers
- [x] Update nixunbound/unbound.nix to use new private subnet & upstreams
- [x] Update nixnginx/auth.js to point to new mail server IP
- [x] Update nixpostgres/postgresql.nix to allow new private subnets in pg_hba
- [x] Update nixmail/nixmail.nix for trusted networks and xclient host
- [x] Update scratch/setup-host-routing.sh to forward to the new container IPs

---

This PR updates the repository to reflect the new container IP assignments and DNS resolver changes requested on 2026-06-14.

Changes:
- hosts.nix
  - Replace 172.16.16.* / fd0c:dead:beef::* with the new addresses for containers:
    - nixwireguard (nixvpn): 10.10.10.5 / fd00::5
    - nixnsd: 10.20.20.11 / fd01::11
    - nixforgejo: 10.20.20.12 / fd01::12
    - nixmail: 10.20.20.13 / fd01::13
    - nixnginx: 10.20.20.14 / fd01::14
    - nixidm: 10.20.20.15 / fd01::15
    - nixunbound: 10.20.20.16 / fd01::16
    - nixpostgresql: 10.20.20.17 / fd01::17
  - Set nameservers to use Unbound at 10.20.20.16 (fd01::16) and fallbacks 185.12.64.1, 2a01:4ff:ff00::add:2, 185.12.64.2

- nixunbound/unbound.nix
  - Allow access from 10.20.20.0/24 and fd01::/64
  - Use nixnsd (10.20.20.11) as stub-zone authoritative server
  - Forward public queries to the provided fallbacks

- nixnginx/auth.js
  - Mail backend host updated to 10.20.20.13

- nixpostgres/postgresql.nix
  - pg_hba rules updated to allow connections from 10.20.20.0/24 and fd01::/64

- nixmail/nixmail.nix
  - adjust haproxy_trusted_networks & smtpd_authorized_xclient_hosts to new IPs/subnets

- scratch/setup-host-routing.sh
  - Update NGINX_IP, VPN_IP, NSD_IP and DNAT rules to reflect new addresses

Deployment notes and checklist are included in the PR body.
