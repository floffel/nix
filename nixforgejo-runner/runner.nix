# NixOS Service Configuration for the Forgejo Actions Runner
{ config, pkgs, lib, ... }:

let
  forgejoRunner = pkgs.forgejo-runner;

  baseConfig = pkgs.writeText "runner-base.yaml" ''
    runner:
      capacity: 4
      labels:
        - ubuntu-latest:docker://node:20-bullseye
        - ubuntu-22.04:docker://node:20-bullseye
        - ubuntu-20.04:docker://node:20-bullseye
        - docker:docker://node:20-bullseye
        - native:host

    container:
      docker_host: automount

    cache:
      enabled: true
      dir: /var/lib/gitea-runner/cache
  '';

  mergeConfig = pkgs.writeShellScript "forgejo-merge-config" ''
    set -euo pipefail
    mkdir -p "$STATE_DIRECTORY/default"
    cd "$STATE_DIRECTORY/default"

    cat > config.yaml <<YAMLEOF
    server:
      connections:
        forgejo:
          url: "http://nixforgejo:3000"
          uuid: "''${RUNNER_UUID}"
          token: "''${RUNNER_TOKEN}"
    YAMLEOF
    cat ${baseConfig} >> config.yaml
  '';
in
{
  virtualisation.docker.enable = true;
  virtualisation.docker.daemon.settings = {
    dns = [ "10.20.20.16" "185.12.64.1" ];
  };
  virtualisation.docker.autoPrune = {
    enable = true;
    dates = "weekly";
    flags = [ "--all" "--filter" "until=168h" ];
  };

  services.gitea-actions-runner = {
    package = forgejoRunner;

    instances.default = {
      enable = true;
      name = "forgejo-runner";
      url = "http://nixforgejo:3000";

      tokenFile = "/var/lib/secrets/forgejo/runner-secrets";

      labels = [
        "ubuntu-latest:docker://node:20-bullseye"
        "ubuntu-22.04:docker://node:20-bullseye"
        "ubuntu-20.04:docker://node:20-bullseye"
        "docker:docker://node:20-bullseye"
        "native:host"
      ];

      settings = {
        container.docker_host = "automount";
      };
    };
  };

  systemd.services.gitea-runner-default.serviceConfig = {
    ExecStartPre = lib.mkForce [ "${mergeConfig}" ];
    ExecStart = lib.mkForce "${forgejoRunner}/bin/forgejo-runner daemon --config /var/lib/gitea-runner/default/config.yaml";
    WorkingDirectory = lib.mkForce "/var/lib/gitea-runner";
  };
}
