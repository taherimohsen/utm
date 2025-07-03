#!/bin/bash
# Ultimate Tunnel Manager - Final Version
set -euo pipefail

# Configurations
CONFIG_DIR="/etc/utm"
LOG_DIR="/var/log/utm"
SSH_KEY="/root/.ssh/utm_key"

# Initialize
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
touch "$LOG_DIR/utm.log"
chmod 600 "$LOG_DIR/utm.log"

function log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_DIR/utm.log"
  echo "$1"
}

function show_header() {
  clear
  echo "========================================"
  echo "  Ultimate Tunnel Manager (Final)"
  echo "========================================"
}

function pause() {
  read -rp "Press Enter to continue..."
}

function get_input() {
  read -rp "$1" input
  echo "$input"
}

function install_dependencies() {
  log "[*] Checking dependencies..."
  apt-get update >/dev/null 2>&1
  
  local deps=(jq dig haproxy ipvsadm sshpass)
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      log "[+] Installing $dep..."
      apt-get install -y "$dep" >/dev/null 2>&1 || {
        log "[!] Failed to install $dep"
        return 1
      }
    fi
  done
  
  # Setup SSH key
  if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q
    chmod 600 "$SSH_KEY"*
  fi
}

function resolve_domain() {
  local domain="$1"
  log "[*] Resolving $domain..."
  local servers=($(dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u))
  
  [ ${#servers[@]} -eq 0 ] && {
    log "[!] No IPs found for $domain"
    return 1
  }
  
  echo "${servers[@]}"
}

function configure_iran_server() {
  local server_id="$1"
  mkdir -p "$CONFIG_DIR/$server_id"
  
  log "[*] Configuring Iranian server..."
  local iran_ip=$(get_input "Iran server IP: ")
  local iran_user=$(get_input "SSH username: ")
  local iran_pass=$(get_input "SSH password: ")
  
  jq -n \
    --arg ip "$iran_ip" \
    --arg user "$iran_user" \
    --arg pass "$iran_pass" \
    '{
      iran_server: {
        ip: $ip,
        user: $user,
        pass: $pass
      },
      foreign_servers: {},
      protocols: {}
    }' > "$CONFIG_DIR/$server_id/config.json"
}

function configure_foreign_server() {
  local server_id="$1"
  local ip="$2"
  
  log "[*] Configuring foreign server $ip..."
  local user=$(get_input "Username for $ip: ")
  local pass=$(get_input "Password for $ip: ")
  
  # Test SSH connection
  if ! sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$user@$ip" "echo SSH test successful" &>/dev/null; then
    log "[!] SSH connection failed to $ip"
    return 1
  fi
  
  # Update config
  jq --arg ip "$ip" \
     --arg user "$user" \
     --arg pass "$pass" \
     '.foreign_servers += {($ip): {user: $user, pass: $pass}}' \
     "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
}

function generate_haproxy_config() {
  local server_id="$1"
  local config_file="$CONFIG_DIR/$server_id/haproxy.cfg"
  
  log "[*] Generating HAProxy config..."
  
  cat > "$config_file" <<EOF
global
  log /dev/log local0
  daemon
  maxconn 2048
  user haproxy
  group haproxy

defaults
  log global
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
  retries 3
EOF

  # Add protocols
  for proto in $(jq -r '.protocols | keys[]' "$CONFIG_DIR/$server_id/config.json"); do
    if [ "$(jq -r ".protocols.$proto.transport" "$CONFIG_DIR/$server_id/config.json")" == "haproxy" ]; then
      local port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
      
      cat >> "$config_file" <<EOF

frontend ${proto}_front
  bind *:$port
  default_backend ${proto}_back

backend ${proto}_back
  mode tcp
  balance roundrobin
  option tcp-check
EOF

      while read -r ip; do
        echo "  server ${proto}_${ip//./_} $ip:$port check" >> "$config_file"
      done < <(jq -r '.foreign_servers | keys[]' "$CONFIG_DIR/$server_id/config.json")
    fi
  done
}

function setup_haproxy_service() {
  local server_id="$1"
  
  log "[*] Setting up HAProxy service..."
  
  # Create systemd service
  cat > "/etc/systemd/system/haproxy-$server_id.service" <<EOF
[Unit]
Description=HAProxy for $server_id
After=network.target

[Service]
ExecStartPre=/usr/sbin/haproxy -f $CONFIG_DIR/$server_id/haproxy.cfg -c -q
ExecStart=/usr/sbin/haproxy -Ws -f $CONFIG_DIR/$server_id/haproxy.cfg -p /run/haproxy-$server_id.pid
ExecReload=/usr/sbin/haproxy -f $CONFIG_DIR/$server_id/haproxy.cfg -c -q
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "haproxy-$server_id" >/dev/null 2>&1
  
  if ! systemctl start "haproxy-$server_id"; then
    log "[!] HAProxy failed to start. Check: journalctl -u haproxy-$server_id -n 30 --no-pager"
    return 1
  fi
  log "[+] HAProxy started successfully"
}

function setup_ipvs() {
  local server_id="$1"
  local proto="$2"
  local port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
  
  log "[*] Setting up IPVS for $proto:$port..."
  
  # Clear existing
  ipvsadm -C
  
  # Add servers
  while read -r ip; do
    ipvsadm -A -u ":$port" -s rr
    ipvsadm -a -u ":$port" -r "$ip:$port" -m
    log "[+] Added $ip:$port to IPVS"
  done < <(jq -r '.foreign_servers | keys[]' "$CONFIG_DIR/$server_id/config.json")
  
  # Save rules
  ipvsadm-save > "/etc/ipvs-$server_id.rules"
  
  # Create systemd service
  cat > "/etc/systemd/system/ipvs-$server_id.service" <<EOF
[Unit]
Description=IPVS for $server_id
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipvsadm-restore < /etc/ipvs-$server_id.rules
ExecStop=/sbin/ipvsadm -C

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "ipvs-$server_id" >/dev/null 2>&1
  systemctl start "ipvs-$server_id"
}

function configure_protocol() {
  local server_id="$1"
  local proto="$2"
  
  log "[*] Configuring $proto..."
  local port=$(get_input "Port number: ")
  local transport="haproxy"
  
  if [ "$proto" == "openvpn" ] || [ "$(get_input "Use IPVS (for UDP)? [y/N]: " | tr '[:upper:]' '[:lower:]')" == "y" ]; then
    transport="ipvs"
  fi
  
  # Update config
  jq --arg proto "$proto" \
     --arg port "$port" \
     --arg transport "$transport" \
     '.protocols += {($proto): {port: $port, transport: $transport}}' \
     "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
  
  # Apply config
  case "$transport" in
    "haproxy")
      generate_haproxy_config "$server_id"
      setup_haproxy_service "$server_id"
      ;;
    "ipvs")
      setup_ipvs "$server_id" "$proto"
      ;;
  esac
}

function remove_server() {
  local server_id="$1"
  
  log "[*] Removing server $server_id..."
  
  # Stop services
  systemctl stop "haproxy-$server_id" 2>/dev/null || true
  systemctl stop "ipvs-$server_id" 2>/dev/null || true
  
  # Disable services
  systemctl disable "haproxy-$server_id" 2>/dev/null || true
  systemctl disable "ipvs-$server_id" 2>/dev/null || true
  
  # Remove files
  rm -f "/etc/systemd/system/haproxy-$server_id.service"
  rm -f "/etc/systemd/system/ipvs-$server_id.service"
  rm -f "/etc/ipvs-$server_id.rules"
  rm -rf "$CONFIG_DIR/$server_id"
  
  systemctl daemon-reload
  log "[+] Server $server_id completely removed"
}

function check_status() {
  local server_id="$1"
  
  echo -e "\n[+] Status for $server_id"
  
  # HAProxy status
  if systemctl is-active "haproxy-$server_id" &>/dev/null; then
    echo " - HAProxy: ACTIVE"
    echo "   Listening ports:"
    ss -tlnp | grep "haproxy" | awk '{print "    - " $4}'
  else
    echo " - HAProxy: INACTIVE"
    echo "   Check: journalctl -u haproxy-$server_id -n 20 --no-pager"
  fi
  
  # IPVS status
  local ipvs_active=0
  for proto in $(jq -r '.protocols | keys[]' "$CONFIG_DIR/$server_id/config.json"); do
    if [ "$(jq -r ".protocols.$proto.transport" "$CONFIG_DIR/$server_id/config.json")" == "ipvs" ]; then
      ipvs_active=1
      local port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
      if ipvsadm -ln | grep -q ":$port"; then
        echo " - IPVS ($proto:$port): ACTIVE"
        ipvsadm -ln | grep ":$port" | sed 's/^/    /'
      else
        echo " - IPVS ($proto:$port): INACTIVE"
      fi
    fi
  done
  
  [ $ipvs_active -eq 0 ] && echo " - IPVS: No UDP protocols configured"
}

function main_menu() {
  install_dependencies
  
  while true; do
    show_header
    echo "1) Add new server"
    echo "2) Check status"
    echo "3) Remove server"
    echo "4) Exit"
    
    case $(get_input "Select option [1-4]: ") in
      1)
        local server_name=$(get_input "Server name (e.g. iran1): ")
        local server_id="${server_name}-$(date +%s | head -c 6)"
        
        # Configure Iranian server
        configure_iran_server "$server_id"
        
        # Configure foreign servers
        local domain=$(get_input "Foreign server domain: ")
        local servers=($(resolve_domain "$domain")) || {
          pause
          continue
        }
        
        for ip in "${servers[@]}"; do
          echo "=== Configuring $ip ==="
          configure_foreign_server "$server_id" "$ip"
        done
        
        # Configure protocols
        PROTOCOLS=(ssh vless vmess openvpn)
        for proto in "${PROTOCOLS[@]}"; do
          if [ "$(get_input "Enable $proto? [y/N]: " | tr '[:upper:]' '[:lower:]')" == "y" ]; then
            configure_protocol "$server_id" "$proto"
          fi
        done
        
        check_status "$server_id"
        ;;
      2)
        if [ -z "$(ls -A "$CONFIG_DIR")" ]; then
          echo "No servers configured!"
        else
          select server in $(ls "$CONFIG_DIR"); do
            check_status "$server"
            break
          done
        fi
        ;;
      3)
        if [ -z "$(ls -A "$CONFIG_DIR")" ]; then
          echo "No servers configured!"
        else
          select server in $(ls "$CONFIG_DIR"); do
            remove_server "$server"
            break
          done
        fi
        ;;
      4) exit 0 ;;
      *) echo "Invalid option!" ;;
    esac
    
    pause
  done
}

# Start
main_menu
