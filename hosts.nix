# Shared hosts and DNS configuration for all containers
{ ... }:

{
  networking = {
    search = [ "hosts.local.minnecker.com" ];
    
    # Configure DNS resolvers
    nameservers = [
      "172.16.16.91"          # Unbound local DNS server (Primary)
      "fd0c:dead:beef::16:91" # Unbound local DNS server IPv6 (Primary)
      "172.16.16.17"          # Gateway/Host DNS (Fallback)
    ];

    # Hosts entries (static resolution fallback)
    extraHosts = ''
      172.16.16.95 nixnginx.hosts.local.minnecker.com nixnginx proxy
      fd0c:dead:beef::16:95 nixnginx.hosts.local.minnecker.com nixnginx proxy
      172.16.16.94 nixidm.hosts.local.minnecker.com nixidm ldap
      fd0c:dead:beef::16:94 nixidm.hosts.local.minnecker.com nixidm ldap
      172.16.16.96 nixmail.hosts.local.minnecker.com nixmail
      fd0c:dead:beef::16:96 nixmail.hosts.local.minnecker.com nixmail
      172.16.16.32 nixvpn.hosts.local.minnecker.com nixvpn
      172.16.16.93 nixpostgres.hosts.local.minnecker.com nixpostgres
      fd0c:dead:beef::16:93 nixpostgres.hosts.local.minnecker.com nixpostgres
      172.16.16.97 nixforgejo.hosts.local.minnecker.com nixforgejo
      fd0c:dead:beef::16:97 nixforgejo.hosts.local.minnecker.com nixforgejo
      172.16.16.36 nixforgejo-runner.hosts.local.minnecker.com nixforgejo-runner
      172.16.16.37 nixmonitoring.hosts.local.minnecker.com nixmonitoring monitoring
      172.16.16.38 nixopenwebui.hosts.local.minnecker.com nixopenwebui openwebui
      172.16.16.12 nixmatrix.hosts.local.minnecker.com nixmatrix matrix
      172.16.16.18 nixvaultwarden.hosts.local.minnecker.com nixvaultwarden vault
      172.16.16.19 nixwikijs.hosts.local.minnecker.com nixwikijs wiki
      172.16.16.20 nixjitsi.hosts.local.minnecker.com nixjitsi meet
      172.16.16.90 nixnsd.hosts.local.minnecker.com nixnsd
      172.16.16.91 nixunbound.hosts.local.minnecker.com nixunbound
    '';
  };
}
