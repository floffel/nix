# NixOS Service Configuration for the Forgejo Actions Runner
{ config, pkgs, lib, ... }:

let
  forgejoRunner = pkgs.forgejo-runner;

  baseConfig = pkgs.writeText "runner-base.yaml" ''
    runner:
      labels:
        - ubuntu-latest:docker://node:20-bullseye
        - ubuntu-22.04:docker://node:20-bullseye
        - ubuntu-20.04:docker://node:20-bullseye
        - native:host
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
        "native:host"
      ];
    };
  };

  systemd.services.gitea-runner-default.serviceConfig = {
    ExecStartPre = lib.mkForce [ "${mergeConfig}" ];
    ExecStart = lib.mkForce "${forgejoRunner}/bin/forgejo-runner daemon --config /var/lib/gitea-runner/default/config.yaml";
    WorkingDirectory = lib.mkForce "/var/lib/gitea-runner";
  };

  systemd.services.docker-weekly-prune = {
    description = "Weekly Docker system prune";
    after = [ "docker.service" ];
    wants = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.docker}/bin/docker system prune -af --filter until=168h";
    };
  };

  systemd.timers.docker-weekly-prune = {
    description = "Weekly Docker system prune timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };
}
