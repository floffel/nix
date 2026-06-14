# Shared hosts and DNS configuration for all containers
{ ... }:

{
  networking = {
    search = [ "hosts.local.minnecker.com" ];
    
    # Configure DNS resolvers
    nameservers = [
      "10.20.20.16"          # Unbound local DNS server (Primary)
      "fd01::16"             # Unbound local DNS server IPv6 (Primary)
      "185.12.64.1"          # Fallback resolver 1
      "2a01:4ff:ff00::add:2" # Fallback resolver IPv6
      "185.12.64.2"          # Fallback resolver 2
    ];

    # Hosts entries (static resolution fallback)
    extraHosts = ''
      10.20.20.14 nixnginx.hosts.local.minnecker.com nixnginx proxy
      fd01::14 nixnginx.hosts.local.minnecker.com nixnginx proxy
      10.20.20.15 nixidm.hosts.local.minnecker.com nixidm ldap
      fd01::15 nixidm.hosts.local.minnecker.com nixidm ldap
      10.20.20.13 nixmail.hosts.local.minnecker.com nixmail
      fd01::13 nixmail.hosts.local.minnecker.com nixmail
      10.10.10.5 nixvpn.hosts.local.minnecker.com nixvpn
      10.20.20.17 nixpostgres.hosts.local.minnecker.com nixpostgres
      fd01::17 nixpostgres.hosts.local.minnecker.com nixpostgres
      10.20.20.12 nixforgejo.hosts.local.minnecker.com nixforgejo
      fd01::12 nixforgejo.hosts.local.minnecker.com nixforgejo
      172.16.16.36 nixforgejo-runner.hosts.local.minnecker.com nixforgejo-runner
      172.16.16.37 nixmonitoring.hosts.local.minnecker.com nixmonitoring monitoring
      172.16.16.38 nixopenwebui.hosts.local.minnecker.com nixopenwebui openwebui
      172.16.16.12 nixmatrix.hosts.local.minnecker.com nixmatrix matrix
      172.16.16.18 nixvaultwarden.hosts.local.minnecker.com nixvaultwarden vault
      172.16.16.19 nixwikijs.hosts.local.minnecker.com nixwikijs wiki
      172.16.16.20 nixjitsi.hosts.local.minnecker.com nixjitsi meet
      10.20.20.11 nixnsd.hosts.local.minnecker.com nixnsd
      10.20.20.16 nixunbound.hosts.local.minnecker.com nixunbound
    '';
  };
}
