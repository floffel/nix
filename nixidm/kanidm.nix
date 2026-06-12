# NixOS Service Configuration for Kanidm Identity Management
{ config, pkgs, lib, ... }:

{
  services.kanidm = {
    # Specify the versioned package required by this NixOS version
    package = pkgs.kanidm_1_10;

    server = {
      enable = true;
      settings = {
        # Bind the HTTP/HTTPS/SSO server to port 8443
        bindaddress = "0.0.0.0:8443";

        # Bind the read-only LDAP compatibility server to port 636
        ldapbindaddress = "0.0.0.0:636";

        # The domain and origin of the identity manager
        domain = "minnecker.com";
        origin = "https://idm.minnecker.com";
        
        # Path to TLS certificates (needed for secure communication)
        tls_chain = "/var/lib/secrets/ssl/minnecker.com/fullchain.pem";
        tls_key = "/var/lib/secrets/ssl/minnecker.com/key.pem";
        
        role = "WriteReplica";
      };
    };
  };
}
