# Shared hosts and DNS configuration for all containers
{ ... }:

{
  networking = {
    # search and nameservers are normally managed by proxmox
    #search = [ "hosts.local.minnecker.com" ];
    
    # Configure DNS resolvers
    #nameservers = [
    #  "172.16.16.17"
    #  "2a01:4ff:ff00::add:2"
    #  "185.12.64.2"
    #];

    # Hosts entries (static resolution fallback)
    extraHosts = ''
      fd0c:dead:beef::16:16 nixidm.hosts.local.minnecker.com nixidm ldap
      172.16.16.31 nixmail.hosts.local.minnecker.com nixmail
      172.16.16.32 nixvpn.hosts.local.minnecker.com nixvpn
      172.16.16.33 nixpostgres.hosts.local.minnecker.com nixpostgres
      172.16.16.35 nixforgejo.hosts.local.minnecker.com nixforgejo
      172.16.16.36 nixforgejo-runner.hosts.local.minnecker.com nixforgejo-runner
      172.16.16.37 nixmonitoring.hosts.local.minnecker.com nixmonitoring monitoring
      172.16.16.38 nixopenwebui.hosts.local.minnecker.com nixopenwebui openwebui
      172.16.16.12 nixmatrix.hosts.local.minnecker.com nixmatrix matrix
      172.16.16.18 nixvaultwarden.hosts.local.minnecker.com nixvaultwarden vault
      172.16.16.19 nixwikijs.hosts.local.minnecker.com nixwikijs wiki
      172.16.16.20 nixjitsi.hosts.local.minnecker.com nixjitsi meet
      172.16.16.21 nixnsd.hosts.local.minnecker.com nixnsd
      172.16.16.22 nixunbound.hosts.local.minnecker.com nixunbound
    '';
  };
}
