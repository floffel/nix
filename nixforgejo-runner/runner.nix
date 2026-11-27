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
    # CI scratch space belongs on its own Proxmox volume, not inside the
    # container rootfs. On 2026-11-26 and again on 2026-11-27 leaked Actions
    # volumes grew /var/lib/docker until the shared ZFS pool hit zero free --
    # and because every container's rootfs is a dataset of that one pool, CI
    # filled the disk underneath postgres and mail. Putting docker on a
    # separate dataset with a 250 GiB refquota (attached as mp0 from storage
    # "fast", see nixforgejo-runner/README.md) turns "CI fills someone else's
    # database disk" into "CI's own volume is full".
    #
    # Deliberately still on the NVMe pool: the other Proxmox storage ("zfs")
    # is a mirror of 7200 rpm HDDs, which would slow every cargo build down.
    data-root = "/var/lib/ci-docker/docker";
  };

  # Without the volume attached, docker must refuse to start instead of
  # silently writing back into the rootfs -- that fallback is the exact state
  # that caused both outages, and from the outside it looks perfectly healthy.
  # Device ids are compared rather than trusting /proc/mountinfo, because
  # Proxmox hands an unprivileged container a bind mount whose source name is
  # the host-side dataset path.
  #
  # mkBefore on ExecStartPre, not preStart: the docker module may already use
  # preStart, and an assignment would replace it. ExecStartPre is a list
  # option, so this adds to whatever the module provides.
  systemd.services.docker.serviceConfig.ExecStartPre = lib.mkBefore [
    (pkgs.writeShellScript "docker-ci-volume-guard" ''
      set -eu
      ${pkgs.coreutils}/bin/mkdir -p /var/lib/ci-docker/docker
      root_dev="$(${pkgs.coreutils}/bin/stat -c %D /)"
      ci_dev="$(${pkgs.coreutils}/bin/stat -c %D /var/lib/ci-docker 2>/dev/null || echo missing)"
      if [ "$ci_dev" = "missing" ] || [ "$ci_dev" = "$root_dev" ]; then
        echo "FATAL: /var/lib/ci-docker is not a separate volume (dev=$ci_dev rootfs=$root_dev)." >&2
        echo "The CI data volume (mp0, fast:subvol-108-mp-0) is not attached. Refusing to" >&2
        echo "start docker on the container rootfs: that is how the shared pool filled." >&2
        exit 1
      fi
    '')
  ];
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

  # Orphaned Actions containers and their scratch volumes. The runner creates
  # one anonymous docker volume per job plus an "-env" companion and deletes
  # both when the job ends; when the runner or the daemon dies mid-job they
  # leak. That leaked twice onto the shared pool: 2026-11-26 (28 volumes,
  # ~115 GB) and again 2026-11-27 (4 containers plus 165 GB of volumes).
  #
  # Why this is not just `docker system prune --volumes`: that would also
  # delete ci-sccache and ci-lambda-binaries (the whitelisted caches in
  # baseConfig are legitimately "unused" between jobs, and re-downloading them
  # costs ~$38/mo of S3 egress). So collect by name shape instead -- job
  # volumes are hex ids with an optional "-env" sibling, the caches are not.
  #
  # Two defects made the first version of this useless, both found by watching
  # it fail in production rather than by reading it:
  #   * it called mktemp, so it needed free disk in order to free disk. On a
  #     full pool it died at startup precisely when it was needed. Scratch
  #     state now lives in /run, which is tmpfs.
  #   * it selected containers with `--filter status=exited` and then skipped
  #     any container whose State.FinishedAt was the zero timestamp. After the
  #     pool filled, dockerd could not persist state: four containers were
  #     still listed as "Up 13 hours" while inspect reported Status=dead,
  #     Pid=0 and FinishedAt=0001-01-01. Nothing matched, so 165 GB stayed.
  #     Selection now asks for the live process id and treats "no process
  #     inside" as finished, whatever state string dockerd prints.
  systemd.services.forgejo-runner-volume-gc = {
    description = "Remove orphaned Actions containers and docker volumes";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    # Hourly rather than daily: a leaking job must not be able to sit on tens
    # of gigabytes overnight, which is what filled the pool between the 01:24
    # ENOSPC and the 09:56 report the next morning.
    startAt = "*-*-* *:00:00";
    path = [ pkgs.docker pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      set -u

      now="$(date +%s)"
      attached="/run/forgejo-gc-attached.$$"
      trap 'rm -f "$attached"' EXIT
      : > "$attached"

      # Garbage == no process inside, regardless of the state string. A job
      # that is really running keeps its container and therefore keeps its
      # volumes reserved by the loop below.
      for cid in $(docker ps -aq --filter name=FORGEJO-ACTIONS-TASK-); do
        pid="$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null || echo 0)"
        if [ "$pid" -gt 0 ] && [ -d "/proc/$pid" ]; then
          continue
        fi
        # FinishedAt is the honest age, but dockerd leaves it at the zero
        # timestamp when it never managed to record the exit; fall back to the
        # start time so a stuck-forever job still ages out.
        since="$(docker inspect -f '{{if ne .State.FinishedAt "0001-01-01T00:00:00Z"}}{{.State.FinishedAt}}{{else}}{{.State.StartedAt}}{{end}}' "$cid" 2>/dev/null || true)"
        started="$(date -d "$since" +%s 2>/dev/null || echo "$now")"
        age=$((now - started))
        if [ "$age" -gt 3600 ]; then
          echo "removing Actions container $cid (no process inside, ${age}s old)"
          docker rm -f "$cid" || true
        fi
      done

      for cid in $(docker ps -aq); do
        docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$cid" 2>/dev/null
      done | tr ' ' '\n' | sort -u > "$attached"

      docker volume ls -q | sort -u | while read -r vol; do
        case "$vol" in ci-*) continue ;; esac
        printf '%s\n' "$vol" | grep -Eq '^[0-9a-f]{16,}(-env)?$' || continue
        grep -Fxq "$vol" "$attached" && continue
        # Ask dockerd where the volume is instead of hardcoding /var/lib/docker:
        # the data root moved to its own volume (see data-root above).
        mount="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
        size="$(du -sh "$mount" 2>/dev/null | cut -f1)"
        echo "removing orphaned volume $vol (${size:-unknown})"
        docker volume rm "$vol" || true
      done

      docker system df
    '';
  };
}
