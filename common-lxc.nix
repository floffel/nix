# Common settings for Proxmox LXC containers
{ config, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # Proxmox LXC Container specific settings
  boot.isContainer = true;
  
  proxmoxLXC = {
    # Set to false to manage networking manually within each configuration.nix
    # If you want Proxmox host to manage network settings via systemd-networkd, set to true.
    manageNetwork = false;
    privileged = false;
  };

  # Disable sandboxing inside the container since LXC profiles usually restrict the system calls Nix sandbox uses
  nix.settings.sandbox = false;

  # Suppress systemd units that are incompatible with LXC containers to avoid boot and rebuild failures
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # Let Proxmox host handle fstrim
  services.fstrim.enable = false;

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
