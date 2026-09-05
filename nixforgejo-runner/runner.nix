# NixOS Service Configuration for the Forgejo Actions Runner
{ config, pkgs, lib, ... }:

let
  forgejoRunner = pkgs.forgejo-runner;

  node20Bullseye = "node:20-bullseye@sha256:c0122351f25f04facee976f9db7214789eabadb489f4e4aea9cd00a0d6af77c4";

  labels = [
    "ubuntu-latest:docker://${node20Bullseye}"
    "ubuntu-22.04:docker://${node20Bullseye}"
    "ubuntu-20.04:docker://${node20Bullseye}"
    "docker:docker://${node20Bullseye}"
    "native:host"
  ];

  labelsYaml = lib.concatStringsSep "\n" (map (l: "        - ${l}") labels);

  baseConfig = pkgs.writeText "runner-base.yaml" ''
    runner:
      capacity: 4
      labels:
        ${labelsYaml}

    container:
      docker_host: automount
      force_pull: true

    cache:
      enabled: true
      dir: /var/lib/gitea-runner/cache
  '';

  mergeConfig = pkgs.writeShellScript "forgejo-merge-config" ''
    set -euo pipefail
    mkdir -p "$STATE_DIRECTORY/default"
    cd "$STATE_DIRECTORY/default"

    uuid="$(printf '%s' "$RUNNER_UUID" | tr -d '\r\n')"
    token="$(printf '%s' "$RUNNER_TOKEN" | tr -d '\r\n')"

    {
      echo "server:"
      echo "  connections:"
      echo "    forgejo:"
      printf '      url: "http://nixforgejo:3000"\n'
      printf '      uuid: "%s"\n' "$uuid"
      printf '      token: "%s"\n' "$token"
    } > config.yaml

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
    dates = "daily";
    flags = [ "--all" "--filter" "until=24h" ];
  };

  services.gitea-actions-runner = {
    package = forgejoRunner;

    instances.default = {
      enable = true;
      name = "forgejo-runner";
      url = "http://nixforgejo:3000";

      tokenFile = "/var/lib/secrets/forgejo/runner-secrets";

      labels = labels;

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

  systemd.services.forgejo-cache-clean = {
    description = "Purge stale Forgejo actions cache archives";
    startAt = "weekly";
    script = ''
      if [ -d /var/lib/gitea-runner/cache ]; then
        ${pkgs.findutils}/bin/find /var/lib/gitea-runner/cache -type f -mtime +14 -delete
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
    };
  };
}
