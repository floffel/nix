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
    "amd64"
  ];

  baseConfig = pkgs.writeText "runner-base.yaml" (lib.concatLines ([
    "  runner:"
    "    capacity: 2"
    "    labels:"
  ] ++ (map (l: "      - ${l}") labels) ++ [
    ""
    "  container:"
    "    docker_host: automount"
    "    force_pull: true"
    # Named docker volumes the CI jobs may mount (2026-10-02): the
    # immosai ci.yml declares `volumes: [ci-sccache:/cache/sccache,
    # ci-lambda-binaries:/ci-lambda-binaries]` so the compile + Lambda
    # binary caches stay runner-local instead of being pulled back out
    # of S3 on every job (~$38/mo egress). act_runner refuses
    # job-declared volumes unless they are whitelisted here; without
    # this the jobs fail at container create ("volume not allowed").
    "    valid_volumes:"
    "      - ci-sccache"
    "      - ci-lambda-binaries"
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
      printf '        url: "https://git.minnecker.com"\n'
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
      url = "https://git.minnecker.com";

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

  # Orphaned Actions scratch volumes. The runner creates one anonymous docker
  # volume per job plus an "-env" companion and deletes both when the job
  # ends; when the runner or the daemon dies mid-job they leak. On 2026-11-26
  # that was 28 volumes / ~115 GB sitting on the same ZFS pool as postgres and
  # mail, and the pool filled up.
  #
  # The daily virtualisation.docker.autoPrune above cannot fix this: `docker
  # system prune` does not touch volumes unless --volumes is passed, and
  # --volumes would delete ci-sccache and ci-lambda-binaries (the whitelisted
  # caches in baseConfig), because those are legitimately "unused" between
  # jobs. So collect by name shape instead: job volumes are hex ids, optional
  # "-env" sibling, and the caches are not.
  systemd.services.forgejo-runner-volume-gc = {
    description = "Remove orphaned Actions containers and docker volumes";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    startAt = "daily";
    path = [ pkgs.docker pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      set -u
      now="$(date +%s)"

      # An exited job container older than 12h belongs to a run that is long
      # gone -- the runner never parks a finished container that long -- and
      # while it exists its volumes still count as "in use" and cannot be
      # collected. Neither half of the obvious one-liner works on docker 29:
      # `docker ps` rejects an `until` filter, and its --format renders a flat
      # row so it cannot range over .Mounts ("range can't iterate over"). Ask
      # inspect per container instead, and keep the template on one line by
      # separating names with spaces.
      for cid in $(docker ps -aq --filter status=exited --filter name=FORGEJO-ACTIONS-TASK-); do
        finished="$(docker inspect -f '{{.State.FinishedAt}}' "$cid" 2>/dev/null || true)"
        case "$finished" in
          ""|0001-01-01*) continue ;;
        esac
        ended="$(date -d "$finished" +%s 2>/dev/null || echo "$now")"
        if [ $((now - ended)) -gt 43200 ]; then
          echo "removing Actions container $cid (finished $((now - ended))s ago)"
          docker rm "$cid" || true
        fi
      done

      attached="$(mktemp)"
      trap 'rm -f "$attached"' EXIT
      for cid in $(docker ps -aq); do
        docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$cid" 2>/dev/null
      done | tr ' ' '\n' | grep -v '^[[:space:]]*$' | sort -u > "$attached"

      docker volume ls -q | sort -u | while read -r vol; do
        case "$vol" in ci-*) continue ;; esac
        printf '%s\n' "$vol" | grep -Eq '^[0-9a-f]{16,}(-env)?$' || continue
        grep -Fxq "$vol" "$attached" && continue
        size="$(du -sh "/var/lib/docker/volumes/$vol" 2>/dev/null | cut -f1)"
        echo "removing orphaned volume $vol ($size)"
        docker volume rm "$vol" || true
      done

      docker system df
    '';
  };
}
