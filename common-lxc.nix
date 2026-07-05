# Common settings for Proxmox LXC containers
{ config, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # Proxmox LXC Container specific settings
  boot.isContainer = true;
  
  proxmoxLXC = {
    # Set to true to manage networking manually within each configuration.nix
    # When false, systemd-networkd is enabled to accept network configuration from Proxmox.
    manageNetwork = false;
    privileged = false;
  };

  # Disable sandboxing inside the container since LXC profiles usually restrict the system calls Nix sandbox uses
  nix.settings.sandbox = false;

  # Garbage-collect old generations weekly to keep the container rootfs from growing.
  # Deletes store paths not reachable from any current generation older than 7 days.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Suppress systemd units that are incompatible with LXC containers to avoid boot and rebuild failures
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # Let Proxmox host handle fstrim
  services.fstrim.enable = false; # Let Proxmox host handle fstrim

  # Limit systemd journal log sizes to prevent disk exhaustion in LXC
  services.journald.extraConfig = ''
    SystemMaxUse=500M
  '';

  # 1. Enable Prometheus Node Exporter globally for system metrics scraping
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" "textfile" ]; # systemd: service status; textfile: custom metrics (e.g. wireguard)
    # Bind on "[::]" so Prometheus (which scrapes by short name, resolving
    # IPv6 first) reaches the exporter. "[::]" dual-stacks on Linux
    # (net.ipv6.bindv6only=0), covering both IPv4 and IPv6. The module
    # concatenates listenAddress:port, so "[::]" yields "[::]:9100".
    listenAddress = "[::]";
    # Textfile collector reads *.prom files from this directory. Services
    # that produce custom metrics (wireguard peer stats, etc.) write here.
    extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter-textfile" ];
  };

  # Ensure the textfile directory exists and is writable by node-exporter
  # (runs as the "node-exporter" user). Services writing metrics should drop
  # files here; node-exporter picks them up on the next scrape.
  systemd.tmpfiles.settings."10-node-exporter-textfile" = {
    "/var/lib/node-exporter-textfile".d = {
      mode = "0755";
      user = "node-exporter";
      group = "node-exporter";
    };
  };

  # 2. Enable Grafana Alloy globally to aggregate and forward journal logs to Loki
  services.alloy = {
    enable = true;
    configPath = pkgs.writeText "config.alloy" ''
      loki.write "local_loki" {
        endpoint {
          url = "http://nixmonitoring:3100/loki/api/v1/push"
        }
      }

      loki.relabel "journal" {
        // Do NOT put forward_to here — this component only defines relabel
        // rules. The journal source applies them via relabel_rules below.
        // Alloy drops __journal_* internal labels BEFORE forwarding to
        // forward_to receivers, so relabeling must happen at the source
        // level via relabel_rules, not in the pipeline.
        forward_to = []
        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "systemd_unit"
        }
        rule {
          source_labels = ["__journal__hostname"]
          target_label  = "host"
        }
      }

      loki.source.journal "read" {
        forward_to    = [loki.write.local_loki.receiver]
        relabel_rules = loki.relabel.journal.rules
        labels        = { job = "systemd-journal" }
      }
    '';
  };

  # Allow Grafana Alloy to read systemd-journal logs
  users.users.alloy = {
    isSystemUser = true;
    group = "alloy";
    extraGroups = [ "systemd-journal" ];
  };
  users.groups.alloy = {};

  # Disable OpenSSH daemon (management is done via Proxmox pct enter)
  services.openssh.enable = false;

  # Disable QEMU Guest Agent since this runs as an LXC container, not a VM
  services.qemuGuest.enable = false;

  # Set your time zone.
  time.timeZone = "Europe/Berlin";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # System-wide packages common to all containers
  environment.systemPackages = with pkgs; [
    vim
    git
    rsync
    htop
    tmux
    dnsutils # provides dig, nslookup, host
    tcpdump
    netcat
    inetutils   # provides telnet and other classic inet tools
  ];

  system.stateVersion = "26.05";
}
