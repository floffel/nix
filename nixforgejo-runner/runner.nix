# NixOS Service Configuration for the Forgejo Actions Runner
{ config, pkgs, lib, ... }:

let
  forgejoRunner = pkgs.forgejo-runner;

  nodeBullseye = "docker.io/library/node:26-bullseye@sha256:784b1bb050f6bf8ccfdc28d9d07ad07d15ab9d72eee5867f875ba219abec2611";

  labels = [
    "ubuntu-latest:docker://${nodeBullseye}"
    "ubuntu-22.04:docker://${nodeBullseye}"
    "ubuntu-20.04:docker://${nodeBullseye}"
    "docker:docker://${nodeBullseye}"
    "native:host"
  ];

  baseConfig = pkgs.writeText "runner-base.yaml" (lib.concatLines ([
    "  runner:"
    "    capacity: 4"
    "    labels:"
  ] ++ (map (l: "      - ${l}") labels) ++ [
    ""
    "  container:"
    "    docker_host: automount"
    "    force_pull: true"
    ""
    "  cache:"
    "    enabled: true"
    "    dir: /var/lib/gitea-runner/cache"
  ]));

  mergeConfig = pkgs.writeShellScript "forgejo-merge-config" ''
    set -euo pipefail
    mkdir -p "$STATE_DIRECTORY/default"
    cd "$STATE_DIRECTORY/default"

    uuid="$(printf '%s' "$RUNNER_UUID" | tr -cd 'A-Za-z0-9_-')"
    token="$(printf '%s' "$RUNNER_TOKEN" | tr -cd 'A-Za-z0-9_-')"

    {
      printf '  server:\n'
      printf '    connections:\n'
      printf '      forgejo:\n'
      printf '        url: "http://nixforgejo:3000"\n'
      printf '        uuid: "%s"\n' "$uuid"
      printf '        token: "%s"\n' "$token"
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
