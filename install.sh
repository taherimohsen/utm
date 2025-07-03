#!/bin/bash
# Ultimate Tunnel Manager with 30-minute session persistence
set -euo pipefail

# Configurations
CONFIG_DIR="/etc/utm"
LOG_DIR="/var/log/utm"
LOCK_DIR="/var/lock/utm"

# Create directories
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$LOCK_DIR"

function show_header() {
  clear
  echo "========================================"
  echo "  Ultimate Tunnel Manager (Persistent)"
  echo "  Version: 3.1 | 30-min Session Persistence"
  echo "========================================"
}

function pause() {
  read -rp "Press Enter to continue..."
}

function install_deps() {
  echo "[*] Installing required packages..."
  apt update && apt install -y \
    ipvsadm haproxy curl dnsutils \
    jq net-tools socat rsyslog
}

function setup_ipvs() {
  local proto=$1
  local port=$2
  local server_id=$3
  shift 3
  local servers=("$@")
  
  local config_file="$CONFIG_DIR/$server_id/ipvs-$proto.sh"

  cat > "$config_file" <<EOF
#!/bin/bash
# IPVS Config for $proto - $server_id with 30-min persistence

# Load kernel modules
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe nf_conntrack_ipv4

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Persistence settings (1800 seconds = 30 minutes)
echo 1800 > /proc/sys/net/ipv4/vs/expire_nodest_conn
echo 1 > /proc/sys/net/ipv4/vs/expire_quiescent_template

# Clear old rules
ipvsadm -C

# Add UDP service with persistence
ipvsadm -A -u 0.0.0.0:$port -s rr -p 1800
EOF

  for ip in "${servers[@]}"; do
    echo "ipvsadm -a -u 0.0.0.0:$port -r $ip:$port -m" >> "$config_file"
  done

  # Health check script
  cat > "$CONFIG_DIR/$server_id/healthcheck-$proto.sh" <<EOF
#!/bin/bash
# Health check for $proto servers

for ip in ${servers[@]}; do
  if ! nc -zuv -w 3 \$ip $port; then
    ipvsadm -d -u 0.0.0.0:$port -r \$ip:$port
    logger -t UTM "Server \$ip:$port removed from rotation"
  else
    ipvsadm -a -u 0.0.0.0:$port -r \$ip:$port -m 2>/dev/null || true
  fi
done
EOF

  chmod +x "$config_file" "$CONFIG_DIR/$server_id/healthcheck-$proto.sh"
  bash "$config_file"

  # Create systemd service
  cat > "/etc/systemd/system/ipvs-$server_id-$proto.service" <<EOF
[Unit]
Description=IPVS for $proto - $server_id
After=network.target

[Service]
ExecStart=$config_file
ExecStartPost=/bin/bash $CONFIG_DIR/$server_id/healthcheck-$proto.sh
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

  # Health check timer
  cat > "/etc/systemd/system/healthcheck-$server_id-$proto.timer" <<EOF
[Unit]
Description=Health check for $proto - $server_id

[Timer]
OnUnitActiveSec=60s
OnBootSec=60s

[Install]
WantedBy=timers.target
EOF

  cat > "/etc/systemd/system/healthcheck-$server_id-$proto.service" <<EOF
[Unit]
Description=Health check for $proto - $server_id

[Service]
ExecStart=/bin/bash $CONFIG_DIR/$server_id/healthcheck-$proto.sh
EOF

  systemctl daemon-reload
  systemctl enable --now "ipvs-$server_id-$proto"
  systemctl enable --now "healthcheck-$server_id-$proto.timer"
}

function setup_haproxy() {
  local server_id=$1
  shift
  local protocols=("$@")
  
  local config_file="$CONFIG_DIR/$server_id/haproxy.cfg"

  cat > "$config_file" <<EOF
global
  log /dev/log local0
  daemon
  maxconn 2048
  tune.ssl.default-dh-param 2048

defaults
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
  timeout tunnel 1h
EOF

  for proto in "${protocols[@]}"; do
    local port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
    local servers=$(jq -r '.foreign_servers | keys[]' "$CONFIG_DIR/$server_id/config.json")
    
    cat >> "$config_file" <<EOF

# $proto configuration
frontend ${proto}_$server_id
  bind *:$port
  default_backend ${proto}_back_$server_id

backend ${proto}_back_$server_id
  mode tcp
  balance source
  stick-table type ip size 200k expire 30m
  stick on src
EOF

    for ip in $servers; do
      echo "  server ${proto}_${ip//./_} $ip:$port check inter 10s fall 3 rise 2" >> "$config_file"
    done
  done

  # Create systemd service
  cat > "/etc/systemd/system/haproxy-$server_id.service" <<EOF
[Unit]
Description=HAProxy for $server_id
After=network.target

[Service]
ExecStart=/usr/sbin/haproxy -f $config_file -p /var/run/haproxy-$server_id.pid
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "haproxy-$server_id"
}

function new_server() {
  show_header
  echo "[*] Setting up new Iranian server"
  
  read -rp "Enter unique server name (e.g. iran1): " server_name
  local server_id="${server_name}-$(date +%s | sha256sum | head -c 6)"
  
  mkdir -p "$CONFIG_DIR/$server_id"
  echo "{}" > "$CONFIG_DIR/$server_id/config.json"

  # Get foreign servers
  read -rp "Enter foreign server IPs (comma separated): " servers_input
  IFS=',' read -ra servers <<< "$servers_input"
  
  declare -A credentials
  for ip in "${servers[@]}"; do
    echo "Credentials for $ip:"
    read -rp "Username: " user
    read -rsp "Password: " pass
    echo
    credentials[$ip]="$user:$pass"
    
    jq --arg ip "$ip" --arg user "$user" --arg pass "$pass" \
      '.foreign_servers += {($ip): {"user": $user, "pass": $pass}}' \
      "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
  done

  # Protocol setup
  PROTOCOLS=(ssh vless vmess openvpn)
  declare -A protocols_to_setup
  
  for proto in "${PROTOCOLS[@]}"; do
    read -rp "Enable $proto? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || continue
    
    read -rp "Port for $proto: " port
    echo "Select transport:"
    echo "1) TCP (HAProxy with 30-min persistence)"
    echo "2) UDP (IPVS with 30-min persistence)"
    read -rp "Choice [1-2]: " choice
    
    if [[ "$choice" == "2" ]]; then
      transport="ipvs"
    else
      transport="haproxy"
    fi
    
    jq --arg proto "$proto" --arg port "$port" --arg transport "$transport" \
      '.protocols += {($proto): {"port": $port, "transport": $transport}}' \
      "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
    
    protocols_to_setup[$proto]=$transport
  done

  # Apply configurations
  for proto in "${!protocols_to_setup[@]}"; do
    port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
    
    case "${protocols_to_setup[$proto]}" in
      ipvs)
        setup_ipvs "$proto" "$port" "$server_id" "${servers[@]}"
        ;;
      haproxy)
        setup_haproxy "$server_id" "$proto"
        ;;
    esac
  done

  # Enable logging
  cat > "/etc/rsyslog.d/utm-$server_id.conf" <<EOF
local0.* /var/log/utm-$server_id.log
EOF
  systemctl restart rsyslog

  echo -e "\n[+] Server $server_id configured successfully!"
  echo -e "Logs: /var/log/utm-$server_id.log"
  pause
}

function remove_server() {
  show_header
  echo "[*] Remove existing server"
  
  if [[ -z $(ls "$CONFIG_DIR") ]]; then
    echo "No servers configured!"
    pause
    return
  fi

  echo "Existing servers:"
  ls "$CONFIG_DIR" | cat -n
  read -rp "Select server number to remove: " num
  
  local servers=($(ls "$CONFIG_DIR"))
  local selected="${servers[$((num-1))]}"
  
  [[ -z "$selected" ]] && { echo "Invalid selection!"; pause; return; }
  
  read -rp "Confirm remove server $selected? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return

  # Stop services
  systemctl stop "haproxy-$selected" 2>/dev/null || true
  systemctl disable "haproxy-$selected" 2>/dev/null || true
  
  for proto in $(jq -r '.protocols | keys[]' "$CONFIG_DIR/$selected/config.json"); do
    transport=$(jq -r ".protocols.$proto.transport" "$CONFIG_DIR/$selected/config.json")
    
    if [[ "$transport" == "ipvs" ]]; then
      systemctl stop "ipvs-$selected-$proto" 2>/dev/null || true
      systemctl stop "healthcheck-$selected-$proto.timer" 2>/dev/null || true
      systemctl disable "ipvs-$selected-$proto" 2>/dev/null || true
      systemctl disable "healthcheck-$selected-$proto.timer" 2>/dev/null || true
      rm -f "/etc/systemd/system/ipvs-$selected-$proto.service" \
            "/etc/systemd/system/healthcheck-$selected-$proto.timer" \
            "/etc/systemd/system/healthcheck-$selected-$proto.service"
    fi
  done

  rm -rf "$CONFIG_DIR/$selected"
  rm -f "/var/log/utm-$selected.log" "/etc/rsyslog.d/utm-$selected.conf"
  systemctl daemon-reload
  systemctl restart rsyslog
  
  echo "[+] Server $selected removed successfully!"
  pause
}

function server_status() {
  show_header
  echo "[*] Current servers status"
  
  if [[ -z $(ls "$CONFIG_DIR") ]]; then
    echo "No servers configured!"
    pause
    return
  fi

  for server in "$CONFIG_DIR"/*; do
    server_id=$(basename "$server")
    echo -e "\nServer: \e[33m$server_id\e[0m"
    
    # HAProxy status
    if systemctl is-active "haproxy-$server_id" &>/dev/null; then
      echo -e " - HAProxy: \e[32mACTIVE\e[0m"
      echo "   Active TCP connections:"
      ss -tnp state established | grep "haproxy-$server_id" | awk '{print $5}' | cut -d: -f2 | sort | uniq -c
    else
      echo -e " - HAProxy: \e[31mINACTIVE\e[0m"
    fi
    
    # IPVS status
    ipvs_status=$(ipvsadm -ln | grep -c "$server_id")
    if (( ipvs_status > 0 )); then
      echo -e " - IPVS: \e[32mACTIVE\e[0m"
      echo "   Active UDP connections:"
      ipvsadm -ln --persistent-conn | grep -A10 "$server_id"
      echo "   Health check logs:"
      tail -n 5 "/var/log/utm-$server_id.log" 2>/dev/null || echo "    No logs found"
    else
      echo -e " - IPVS: \e[31mINACTIVE\e[0m"
    fi
  done
  
  pause
}

function main_menu() {
  while true; do
    show_header
    echo "Main Menu:"
    echo "1) Add new Iranian server"
    echo "2) Remove Iranian server"
    echo "3) View status"
    echo "4) Exit"
    
    read -rp "Select option [1-4]: " choice
    
    case $choice in
      1) install_deps; new_server;;
      2) remove_server;;
      3) server_status;;
      4) exit 0;;
      *) echo "Invalid option!"; pause;;
    esac
  done
}

# Start
main_menu
