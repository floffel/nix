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
    hostName = "nixvpn";

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
      privateKeyFile = "/var/lib/secrets/nixvpn/private.key";

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
	{ # home
          publicKey = "CLpdpnOTGlcFZLTIp3sSd7NSJfifjNeqM1kVjD4041k=";
	  allowedIPs = [ "10.100.0.2/32" "192.168.1.0/24" ];
          persistentKeepalive = 25;
	}
	{ # small pc
          publicKey = "sqxfw2rgh/qDFmws79rJOaoWsRnWwb7GXdDDPpSNnk0=";
	  allowedIPs = [ "10.100.0.4/32" ];
          persistentKeepalive = 25;
	}
        { # mobile
          publicKey = "j9zkTS61Os59Faz5pRscSYGTUwSgedTMOZszgzxfiQ0=";
          allowedIPs = [ "10.100.0.5/32" ];
          persistentKeepalive = 25;
        }
        { # macbook
          publicKey = "gu/znY0wZFyzXVjIhYkhNfNcSqkikmbiRo+k+NtM5DA=";
          allowedIPs = [ "10.100.0.3/32" ];
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

  # WireGuard peer metrics for Prometheus via node_exporter's textfile
  # collector. A systemd timer runs `wg show all dump` every 30s and writes
  # Prometheus-format metrics to /var/lib/node-exporter-textfile/wireguard.prom.
  # Exposes per-peer: last handshake timestamp, rx/tx bytes, endpoint, and
  # connection status (handshake within last 3 minutes = "connected").
  systemd.services.wireguard-metrics = {
    description = "Export WireGuard peer stats for Prometheus textfile collector";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    path = [ pkgs.wireguard-tools pkgs.coreutils pkgs.gawk ];
    script = ''
      OUT=/var/lib/node-exporter-textfile/wireguard.prom
      mkdir -p "$(dirname "$OUT")"
      TMP=$(mktemp)
      echo "# HELP wireguard_peer_last_handshake_seconds Unix timestamp of last handshake" > "$TMP"
      echo "# TYPE wireguard_peer_last_handshake_seconds gauge" >> "$TMP"
      echo "# HELP wireguard_peer_rx_bytes Bytes received from peer" >> "$TMP"
      echo "# TYPE wireguard_peer_rx_bytes counter" >> "$TMP"
      echo "# HELP wireguard_peer_tx_bytes Bytes sent to peer" >> "$TMP"
      echo "# TYPE wireguard_peer_tx_bytes counter" >> "$TMP"
      echo "# HELP wireguard_peer_connected 1 if peer handshake within last 3 min, 0 otherwise" >> "$TMP"
      echo "# TYPE wireguard_peer_connected gauge" >> "$TMP"
      echo "# HELP wireguard_peer_info Static peer info (endpoint, allowed IPs)" >> "$TMP"
      echo "# TYPE wireguard_peer_info gauge" >> "$TMP"

      NOW=$(date +%s)

      # wg show all dump output format (tab-separated):
      # interface  peer-key  endpoint  allowed-ips  latest-handshake  transfer-rx  transfer-tx  persistent-keepalive
      wg show all dump 2>/dev/null | while IFS=$'\t' read -r iface pubkey endpoint allowed_ips handshake rx tx keepalive; do
        [ -z "$pubkey" ] && continue
        # Sanitize for Prometheus label values
        ep_clean=$(printf '%s' "$endpoint" | tr -d ' ' | sed 's/:/\\:/g')
        ai_clean=$(printf '%s' "$allowed_ips" | tr ',' ' ' | sed 's/:/\\:/g')
        # Connection status: handshake within last 180s
        if [ -n "$handshake" ] && [ "$handshake" -gt 0 ]; then
          AGE=$((NOW - handshake))
          if [ "$AGE" -lt 180 ]; then
            CONNECTED=1
          else
            CONNECTED=0
          fi
        else
          CONNECTED=0
          handshake=0
        fi
        echo "wireguard_peer_last_handshake_seconds{interface=\"$iface\",peer=\"$pubkey\"} $handshake" >> "$TMP"
        echo "wireguard_peer_rx_bytes{interface=\"$iface\",peer=\"$pubkey\"} $rx" >> "$TMP"
        echo "wireguard_peer_tx_bytes{interface=\"$iface\",peer=\"$pubkey\"} $tx" >> "$TMP"
        echo "wireguard_peer_connected{interface=\"$iface\",peer=\"$pubkey\"} $CONNECTED" >> "$TMP"
        echo "wireguard_peer_info{interface=\"$iface\",peer=\"$pubkey\",endpoint=\"$ep_clean\",allowed_ips=\"$ai_clean\"} 1" >> "$TMP"
      done

      mv "$TMP" "$OUT"
      chmod 644 "$OUT"
    '';
  };

  systemd.timers.wireguard-metrics = {
    wantedBy = [ "multi-user.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "30s";
    };
  };
}
