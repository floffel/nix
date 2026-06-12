# NixOS WireGuard Gateway Server Configuration for the Proxmox Guest Container
{ config, pkgs, ... }:

{
  imports = [
    ../common-lxc.nix
    ../hosts.nix
  ];

  # Enable IP Forwarding in the kernel (essential for routing client traffic)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Networking Setup
  networking = {
    hostName = "nixos-vpn";

    # Configure your network interfaces
    useDHCP = false;

    # Firewall configuration disabled per environment requirements
    firewall = {
      enable = false;
    };

    # WireGuard VPN Interface (using wg-quick for compatibility with systemd-networkd)
    wg-quick.interfaces.wg0 = {
      # The IP address range of the VPN tunnel itself
      address = [ "10.100.0.1/24" ];
      
      # The port to listen on
      listenPort = 51820;
      
      # Path to the private key (stored securely outside the Nix store)
      privateKeyFile = "/var/lib/secrets/wireguard/private.key";

      # Optimize MTU for mobile networks (LTE/5G tunnels reduce available MTU)
      # 1360 is standard to prevent cellular packet fragmentation drops
      mtu = 1360;
      
      # Post-setup commands: Enable NAT/Masquerading for traffic from wg0 to eth0
      # Also enable TCP MSS Clamping to prevent PMTU path issues on mobile carriers
      postUp = ''
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
        ${pkgs.iptables}/bin/iptables -A FORWARD -i wg0 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        ${pkgs.iptables}/bin/iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      '';
      
      # Post-shutdown commands: Clean up NAT and MSS clamping rules
      postDown = ''
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
        ${pkgs.iptables}/bin/iptables -D FORWARD -i wg0 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        ${pkgs.iptables}/bin/iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      '';
      
      # Peer definitions (VPN Clients)
      peers = [
        # Example Client: Mobile Phone (uses floating IP)
        {
          # Mobile Phone's Public Key (generated on the phone)
          # TODO: Replace with the actual public key from the client phone/device
          publicKey = "95PVMFZPTZ2URni05eiwxq88ImEjYpi9lfOVFTQ48TQ=";
          
          # Assign a static IP inside the tunnel to the phone
          allowedIPs = [ "10.100.0.2/32" ];

          # Send a keepalive packet every 25 seconds to keep the NAT mappings alive
          # on mobile networks and speed up endpoint dynamic updates
          persistentKeepalive = 25;
        }
      ];
    };
  };

  # System-wide packages specific to the WireGuard Gateway
  environment.systemPackages = with pkgs; [
    wireguard-tools # provides wg, wg-quick
    iptables
  ];
}
