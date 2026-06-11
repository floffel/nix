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
      fd0c:dead:beef::16:16 ldap
      172.16.16.31 backendmailng.hosts.local.minnecker.com backendmailng
      172.16.16.32 nixos-vpn.hosts.local.minnecker.com nixos-vpn
    '';
  };
}
