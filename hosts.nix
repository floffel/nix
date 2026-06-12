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
      fd0c:dead:beef::16:16 idm.hosts.local.minnecker.com idm ldap
      172.16.16.31 backendmailng.hosts.local.minnecker.com backendmailng
      172.16.16.32 nixos-vpn.hosts.local.minnecker.com nixos-vpn
      172.16.16.33 postgresqlng.hosts.local.minnecker.com postgresqlng
      172.16.16.35 forgejo.hosts.local.minnecker.com forgejo
      172.16.16.36 forgejo-runner.hosts.local.minnecker.com forgejo-runner
      172.16.16.37 monitoringng.hosts.local.minnecker.com monitoringng monitoring
      172.16.16.38 openwebuing.hosts.local.minnecker.com openwebuing openwebui
      172.16.16.12 matrixng.hosts.local.minnecker.com matrixng matrix
      172.16.16.18 vaultwardenng.hosts.local.minnecker.com vaultwardenng vault
      172.16.16.19 wikijsng.hosts.local.minnecker.com wikijsng wiki
      172.16.16.20 jitsing.hosts.local.minnecker.com jitsing meet
    '';
  };
}
