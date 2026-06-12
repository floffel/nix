#!/usr/bin/env bash
# Helper script to manage port forwarding and rate limiting on the Proxmox host
# Usage: ./setup-host-routing.sh [enable|disable|status]

# --- Configuration ---
# Set the public interface of your Proxmox host (e.g., vmbr0, eth0, or enp6s0)
PUB_IF="enp6s0"

# Container IPs matching hosts.nix
NGINX_IP="172.16.16.3"
VPN_IP="172.16.16.32"
NSD_IP="172.16.16.90"
JITSI_IP="172.16.16.20"

# Rules definition: "PROTOCOL:HOST_PORT:CONTAINER_IP:CONTAINER_PORT:LIMIT_TYPE:LIMIT_VALUE"
# LIMIT_TYPE: "syn" (TCP new connection limit per minute), "udp" (UDP packets per second), "none"
RULES=(
  # Nginx (Web)
  "tcp:80:${NGINX_IP}:80:syn:100"
  "tcp:443:${NGINX_IP}:443:syn:150"
  
  # Nginx (Mail Proxy)
  "tcp:25:${NGINX_IP}:25:syn:20"
  "tcp:143:${NGINX_IP}:143:syn:50"
  "tcp:993:${NGINX_IP}:993:syn:50"
  "tcp:110:${NGINX_IP}:110:syn:30"
  "tcp:995:${NGINX_IP}:995:syn:30"
  "tcp:587:${NGINX_IP}:587:syn:30"
  
  # WireGuard VPN
  "udp:51820:${VPN_IP}:51820:udp:300"
  
  # NSD (DNS)
  "udp:53:${NSD_IP}:53:udp:40"
  "tcp:53:${NSD_IP}:53:syn:15"
  
  # Jitsi Video Bridge
  "udp:10000:${JITSI_IP}:10000:udp:2000"
)

# --- Functions ---
enable_forwarding() {
  echo "Enabling IP forwarding in kernel..."
  sysctl -w net.ipv4.ip_forward=1 > /dev/null

  echo "Applying NAT port-forwarding and rate-limiting rules..."
  for rule in "${RULES[@]}"; do
    IFS=":" read -r proto port dst_ip dst_port lim_type lim_val <<< "$rule"
    
    # 1. Apply NAT DNAT rule
    if ! iptables -t nat -C PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}" 2>/dev/null; then
      iptables -t nat -A PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}"
      echo "  [+] NAT: Forwarded ${proto^^} port ${port} -> ${dst_ip}:${dst_port}"
    else
      echo "  [=] NAT: Rule already exists for ${proto^^} port ${port}"
    fi

    # 2. Apply Rate Limiting rule in FORWARD chain
    if [ "$lim_type" = "syn" ]; then
      # TCP SYN rate limit (limits connection attempts per minute from a single source IP)
      if ! iptables -C FORWARD -i "$PUB_IF" -p tcp -d "$dst_ip" --dport "$dst_port" --syn -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/min" --hashlimit-mode srcip --hashlimit-htable-expire 60000 -j DROP 2>/dev/null; then
        iptables -I FORWARD -i "$PUB_IF" -p tcp -d "$dst_ip" --dport "$dst_port" --syn -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/min" --hashlimit-mode srcip --hashlimit-htable-expire 60000 -j DROP
        echo "  [+] Limit: TCP SYN ${port} -> ${lim_val}/min per IP"
      else
        echo "  [=] Limit: TCP SYN limit already exists for port ${port}"
      fi
    elif [ "$lim_type" = "udp" ]; then
      # UDP packet rate limit (limits UDP packets per second from a single source IP)
      if ! iptables -C FORWARD -i "$PUB_IF" -p udp -d "$dst_ip" --dport "$dst_port" -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/sec" --hashlimit-mode srcip --hashlimit-htable-expire 10000 -j DROP 2>/dev/null; then
        iptables -I FORWARD -i "$PUB_IF" -p udp -d "$dst_ip" --dport "$dst_port" -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/sec" --hashlimit-mode srcip --hashlimit-htable-expire 10000 -j DROP
        echo "  [+] Limit: UDP packets ${port} -> ${lim_val}/sec per IP"
      else
        echo "  [=] Limit: UDP limit already exists for port ${port}"
      fi
    fi
  done
}

disable_forwarding() {
  echo "Removing NAT port-forwarding and rate-limiting rules..."
  for rule in "${RULES[@]}"; do
    IFS=":" read -r proto port dst_ip dst_port lim_type lim_val <<< "$rule"
    
    # 1. Remove NAT DNAT rule
    if iptables -t nat -C PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}" 2>/dev/null; then
      iptables -t nat -D PREROUTING -i "$PUB_IF" -p "$proto" --dport "$port" -j DNAT --to-destination "${dst_ip}:${dst_port}"
      echo "  [-] NAT: Removed forward for ${proto^^} port ${port}"
    fi

    # 2. Remove Rate Limiting rule
    if [ "$lim_type" = "syn" ]; then
      if iptables -C FORWARD -i "$PUB_IF" -p tcp -d "$dst_ip" --dport "$dst_port" --syn -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/min" --hashlimit-mode srcip --hashlimit-htable-expire 60000 -j DROP 2>/dev/null; then
        iptables -D FORWARD -i "$PUB_IF" -p tcp -d "$dst_ip" --dport "$dst_port" --syn -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/min" --hashlimit-mode srcip --hashlimit-htable-expire 60000 -j DROP
        echo "  [-] Limit: Removed TCP SYN limit for port ${port}"
      fi
    elif [ "$lim_type" = "udp" ]; then
      if iptables -C FORWARD -i "$PUB_IF" -p udp -d "$dst_ip" --dport "$dst_port" -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/sec" --hashlimit-mode srcip --hashlimit-htable-expire 10000 -j DROP 2>/dev/null; then
        iptables -D FORWARD -i "$PUB_IF" -p udp -d "$dst_ip" --dport "$dst_port" -m hashlimit --hashlimit-name "lim-${dst_port}" --hashlimit-above "${lim_val}/sec" --hashlimit-mode srcip --hashlimit-htable-expire 10000 -j DROP
        echo "  [-] Limit: Removed UDP packet limit for port ${port}"
      fi
    fi
  done
}

show_status() {
  echo "=== Active NAT Port Forwarding Rules ==="
  iptables -t nat -L PREROUTING -v -n --line-numbers | grep -E "dpt:|DNAT"
  
  echo ""
  echo "=== Active Rate Limiting Rules (FORWARD) ==="
  iptables -L FORWARD -v -n --line-numbers | grep -E "limit|hashlimit|DROP"
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
