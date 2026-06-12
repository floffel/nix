#!/usr/bin/env bash
# Helper script to manage port forwarding on the Proxmox host
# Usage: ./setup-host-routing.sh [enable|disable|status]

# --- Configuration ---
# Set the public interface of your Proxmox host (e.g., vmbr0, eth0, or enp3s0)
PUB_IF="vmbr0"

# Container IPs matching hosts.nix
NGINX_IP="172.16.16.3"
VPN_IP="172.16.16.32"
NSD_IP="172.16.16.90"
JITSI_IP="172.16.16.20"

# Rules definition: "PROTOCOL:HOST_PORT:CONTAINER_IP:CONTAINER_PORT"
RULES=(
  # Nginx (Web & Mail proxy)
  "tcp:80:${NGINX_IP}:80"
  "tcp:443:${NGINX_IP}:443"
  "tcp:25:${NGINX_IP}:25"
  "tcp:143:${NGINX_IP}:143"
  "tcp:993:${NGINX_IP}:993"
  "tcp:110:${NGINX_IP}:110"
  "tcp:995:${NGINX_IP}:995"
  "tcp:587:${NGINX_IP}:587"
  
  # WireGuard VPN
  "udp:51820:${VPN_IP}:51820"
  
  # NSD (DNS)
  "udp:53:${NSD_IP}:53"
  "tcp:53:${NSD_IP}:53"
  
  # Jitsi Video Bridge
  "udp:10000:${JITSI_IP}:10000"
)

# --- Functions ---
enable_forwarding() {
  echo "Enabling IP forwarding in kernel..."
  sysctl -w net.ipv4.ip_forward=1 > /dev/null

  echo "Applying NAT port-forwarding rules..."
  for rule in "${RULES[@]}"; do
    IFS=":" read -r proto port dst_ip dst_port <<< "$rule"
    
    # Check if the rule already exists to avoid duplication
    if ! iptables -t nat -C PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}" 2>/dev/null; then
      iptables -t nat -A PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}"
      echo "  [+] Forwarded ${proto^^} port ${port} -> ${dst_ip}:${dst_port}"
    else
      echo "  [=] Rule already exists for ${proto^^} port ${port}"
    fi
  done
}

disable_forwarding() {
  echo "Removing NAT port-forwarding rules..."
  for rule in "${RULES[@]}"; do
    IFS=":" read -r proto port dst_ip dst_port <<< "$rule"
    
    # Check if the rule exists before trying to delete it
    if iptables -t nat -C PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}" 2>/dev/null; then
      iptables -t nat -D PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}"
      echo "  [-] Removed forward for ${proto^^} port ${port}"
    fi
  done
}

show_status() {
  echo "=== Active NAT Port Forwarding Rules on $PUB_IF ==="
  iptables -t nat -L PREROUTING -v -n --line-numbers | grep -E "dpt:|DNAT"
}

# --- Main ---
case "$1" in
  enable)
    enable_forwarding
    ;;
  disable)
    disable_forwarding
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}"
    exit 1
    ;;
esac
