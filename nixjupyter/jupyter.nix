# NixOS Service Configuration for JupyterLab (nixjupyter)
#
# Replaces the podman container that ran on saver CT 107
# (`quay.io/jupyter/datascience-notebook`, host port 8004, token in
# docker-compose.yml).  Three deliberate departures from the old setup:
#
#   * nixpkgs has no `services.jupyter` module, so this is a plain systemd
#     unit running `jupyter-lab` from a pinned python environment.  Nothing is
#     pip-installed at runtime: the whole kernel environment is a store
#     derivation, so a rebuild produces exactly the same packages.
#   * The access token is generated on first start into the state directory
#     instead of living in a compose file.  It never enters the Nix store, and
#     vzdump plus the nightly restic run cover it like every other secret that
#     belongs to a single service.
#   * Access is HTTPS only, through nixnginx.  The old server spoke plain HTTP
#     on a LAN port and put the token in the URL.
#
# The package list is not a guess — it is the set of third-party modules the 42
# migrated notebooks actually import (matplotlib 38, numpy 30, pandas 26,
# tabulate 12, seaborn 4, Bio/biopython 4, sklearn 2, plotly 1; everything else
# was stdlib).  See README.md for how that was measured.
{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/jupyter";
  workDir = "${stateDir}/work";
  envFile = "/run/jupyter/env";

  labEnv = pkgs.python3.withPackages (ps: with ps; [
    jupyterlab
    notebook
    ipykernel
    ipywidgets
    matplotlib
    numpy
    pandas
    seaborn
    scikit-learn
    statsmodels
    sympy
    plotly
    tabulate
    biopython
  ]);

  # Deliberately a store file: nothing in it is secret.  The token is read from
  # the environment at runtime, and `os.environ[...]` (not `.get`) means a
  # missing token aborts startup instead of silently opening an unauthenticated
  # code-execution server.
  serverConfig = pkgs.writeText "jupyter-server-config.py" ''
    import os

    c.ServerApp.ip = "::"
    c.ServerApp.port = 8888
    c.ServerApp.token = os.environ["JUPYTER_TOKEN"]
    c.ServerApp.password = ""
    c.ServerApp.password_required = False
    c.ServerApp.allow_password_change = False
    c.ServerApp.open_browser = False

    c.ServerApp.root_dir = "${workDir}"
    c.ServerApp.preferred_dir = "${workDir}"

    # nixnginx is the only client.  trust_xheaders makes Jupyter take the real
    # scheme from X-Forwarded-Proto, which is what keeps the websocket URLs on
    # wss:// instead of ws://; without allow_remote_access every request is
    # refused because the container only ever sees a proxied Host header.
    c.ServerApp.trust_xheaders = True
    c.ServerApp.allow_remote_access = True
    c.ServerApp.allow_origin = "https://lab.minnecker.com"
    c.ServerApp.allow_credentials = True

    # Terminals would default to /bin/bash, which does not exist on NixOS.
    c.ServerApp.terminado_settings = { "shell_command": ["${pkgs.bash}/bin/bash"] }

    # If the ipykernel kernelspec is not picked up from the environment,
    # jupyter_server builds a native kernel from its own interpreter rather
    # than showing "no kernels available".
    c.KernelSpecManager.ensure_native_kernel = True
  '';
in
{
  users.groups.jupyter = { };
  users.users.jupyter = {
    isSystemUser = true;
    group = "jupyter";
    home = stateDir;
  };

  # Two jobs in one oneshot: mint the token once, then hand it to the service
  # as an EnvironmentFile.  Wanted by — and ordered before — jupyter.service,
  # following the paperless-secrets / wikijs-secrets pattern in this repo.  No
  # partOf/bindsTo: an exited oneshot must not take the server down.
  systemd.services.jupyter-secrets = {
    description = "Provide the Jupyter access token as a runtime env file";
    wantedBy = [ "jupyter.service" ];
    before = [ "jupyter.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      state=${stateDir}/state
      install -d -m 700 -o jupyter -g jupyter "$state"
      if [ ! -s "$state/token" ]; then
        echo "Generating a new Jupyter access token"
        ( umask 077
          head -c 32 /dev/urandom | base64 | tr -d '=+/\n' > "$state/token" )
        chown jupyter:jupyter "$state/token"
        chmod 600 "$state/token"
      fi
      install -d -m 700 /run/jupyter
      ( umask 077
        printf 'JUPYTER_TOKEN=%s\n' "$(cat "$state/token")" > ${envFile} )
      chmod 600 ${envFile}
    '';
  };

  systemd.services.jupyter = {
    description = "JupyterLab";
    documentation = [ "https://jupyterlab.readthedocs.io" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "jupyter-secrets.service" ];

    serviceConfig = {
      ExecStart = "${labEnv}/bin/jupyter-lab --config=${serverConfig} --no-browser";
      User = "jupyter";
      Group = "jupyter";
      WorkingDirectory = workDir;
      # Declared, not created at runtime: systemd makes both directories before
      # ExecStart and hands them to the service user.  Listing `jupyter/work`
      # matters — the unit's WorkingDirectory is that path, and a missing
      # WorkingDirectory is a status=200/CHDIR start failure, which is how the
      # very first boot of this container behaved before any notebooks were
      # seeded.
      StateDirectory = [ "jupyter" "jupyter/work" ];
      EnvironmentFile = envFile;
      # The python environment doubles as the kernel, and matplotlib, jupyter
      # and ipywidgets all cache under $HOME / XDG dirs — point those at the
      # state directory, which is the one place this container may write.
      Environment = [
        "HOME=${stateDir}"
        "XDG_CACHE_HOME=${stateDir}/cache"
        "XDG_DATA_HOME=${stateDir}/data"
        "JUPYTER_PATH=${labEnv}/share/jupyter"
        "MPLBACKEND=Agg"
      ];

      Restart = "on-failure";
      RestartSec = 5;

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ stateDir ];
      UMask = "0027";
    };
  };

  # The notebooks live in the state directory, which is on the container rootfs
  # and therefore inside the nightly vzdump/restic scope.  Nothing else in this
  # container is stateful: rebuilding it only ever replaces store paths.
}
