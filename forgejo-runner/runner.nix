# NixOS Service Configuration for the Forgejo Actions Runner
{ config, pkgs, lib, ... }:

{
  # Enable Docker daemon for running containerized Actions steps
  virtualisation.docker.enable = true;

  # Enable the Forgejo Actions Runner service
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    
    instances.default = {
      enable = true;
      name = "forgejo-runner";
      url = "http://forgejo:3000";
      
      # Path to the registration token file (containing the TOKEN environment variable)
      # Stored securely outside the Nix store
      tokenFile = "/var/lib/secrets/forgejo/runner-token";
      
      labels = [
        "ubuntu-latest:docker://node:20-bullseye"
        "ubuntu-22.04:docker://node:20-bullseye"
        "ubuntu-20.04:docker://node:20-bullseye"
        "native:host"
      ];
    };
  };
}
