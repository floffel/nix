# Shared hosts and DNS configuration for all containers
{ ... }:

{
  networking = {
    search = [ "hosts.local.minnecker.com" ];
    
    # Configure DNS resolvers
    nameservers = [
      "10.20.20.16"            # Unbound local DNS server (Primary)
      "fd01::16"               # Unbound local DNS server IPv6 (Primary)
      "185.12.64.1"
      "2a01:4ff:ff00::add:2"
      "185.12.64.2"
    ];

    # Hosts entries (static resolution fallback)
    extraHosts = ''
      10.10.10.5 nixwireguard.hosts.local.minnecker.com nixwireguard
      fd00::5 nixwireguard.hosts.local.minnecker.com nixwireguard
      10.20.20.11 nixnsd.hosts.local.minnecker.com nixnsd
      fd01::11 nixnsd.hosts.local.minnecker.com nixnsd
      10.20.20.12 nixforgejo.hosts.local.minnecker.com nixforgejo
      fd01::12 nixforgejo.hosts.local.minnecker.com nixforgejo
      10.20.20.13 nixmail.hosts.local.minnecker.com nixmail
      fd01::13 nixmail.hosts.local.minnecker.com nixmail
      10.20.20.14 nixnginx.hosts.local.minnecker.com nixnginx proxy
      fd01::14 nixnginx.hosts.local.minnecker.com nixnginx proxy
      10.20.20.15 nixidm.hosts.local.minnecker.com nixidm ldap
      fd01::15 nixidm.hosts.local.minnecker.com nixidm ldap
      10.20.20.16 nixunbound.hosts.local.minnecker.com nixunbound
      fd01::16 nixunbound.hosts.local.minnecker.com nixunbound
      10.20.20.17 nixpostgresql.hosts.local.minnecker.com nixpostgresql nixpostgres
      fd01::17 nixpostgresql.hosts.local.minnecker.com nixpostgresql nixpostgres
      10.20.20.18 nixforgejo-runner.hosts.local.minnecker.com nixforgejo-runner
      fd01::18 nixforgejo-runner.hosts.local.minnecker.com nixforgejo-runner
      10.20.20.19 nixmatrix.hosts.local.minnecker.com nixmatrix
      fd01::19 nixmatrix.hosts.local.minnecker.com nixmatrix
      10.20.20.20 nixvaultwarden.hosts.local.minnecker.com nixvaultwarden
      fd01::20 nixvaultwarden.hosts.local.minnecker.com nixvaultwarden
      10.20.20.21 nixwikijs.hosts.local.minnecker.com nixwikijs
      fd01::21 nixwikijs.hosts.local.minnecker.com nixwikijs
      10.20.20.22 nixjitsi.hosts.local.minnecker.com nixjitsi
      fd01::22 nixjitsi.hosts.local.minnecker.com nixjitsi
      10.20.20.23 nixmonitoring.hosts.local.minnecker.com nixmonitoring
      fd01::23 nixmonitoring.hosts.local.minnecker.com nixmonitoring
      10.20.20.24 nixopenwebui.hosts.local.minnecker.com nixopenwebui
      fd01::24 nixopenwebui.hosts.local.minnecker.com nixopenwebui
    '';
  };
}
