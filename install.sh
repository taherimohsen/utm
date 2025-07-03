#!/bin/bash
# Ultimate Tunnel Manager - Operational Version
set -euo pipefail

# Configurations
CONFIG_DIR="/etc/utm"
LOG_DIR="/var/log/utm"
SSH_KEY="/root/.ssh/utm_key"

# Initialize directories
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
  echo "  Ultimate Tunnel Manager (Operational)"
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
  log "[*] Checking and installing dependencies..."
  apt-get update >/dev/null 2>&1
  
  local dependencies=(jq dig haproxy ipvsadm sshpass)
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      log "[+] Installing $dep..."
      apt-get install -y "$dep" >/dev/null 2>&1
    fi
  done
  
  # Setup SSH key if not exists
  if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q
    chmod 600 "$SSH_KEY"*
  fi
}

function setup_dns_resolution() {
  local domain="$1"
  log "[*] Resolving $domain..."
  local servers=($(dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u))
  
  if [ ${#servers[@]} -eq 0 ]; then
    log "[!] Error: No servers found for domain $domain"
    return 1
  fi
  
  echo "${servers[@]}"
}

function configure_iran_server() {
  local server_id="$1"
  local iran_ip="$2"
  local iran_user="$3"
  local iran_pass="$4"
  
  log "[*] Configuring Iranian server $iran_ip..."
  
  # Prepare configuration files
  mkdir -p "$CONFIG_DIR/$server_id"
  
  # Save basic info
  jq -n \
    --arg iran_ip "$iran_ip" \
    --arg iran_user "$iran_user" \
    --arg iran_pass "$iran_pass" \
    '{
      iran_server: {
        ip: $iran_ip,
        user: $iran_user,
        pass: $iran_pass
      },
      foreign_servers: {},
      protocols: {}
    }' > "$CONFIG_DIR/$server_id/config.json"
}

function configure_foreign_server() {
  local server_id="$1"
  local foreign_ip="$2"
  local foreign_user="$3"
  local foreign_pass="$4"
  
  log "[*] Configuring foreign server $foreign_ip..."
  
  # Copy SSH key to foreign server
  if ! sshpass -p "$foreign_pass" ssh-copy-id -o StrictHostKeyChecking=no -i "$SSH_KEY" "$foreign_user@$foreign_ip" &>/dev/null; then
    log "[!] Failed to copy SSH key to $foreign_ip"
    return 1
  fi
  
  # Update configuration
  jq --arg ip "$foreign_ip" \
     --arg user "$foreign_user" \
     --arg pass "$foreign_pass" \
     '.foreign_servers += {($ip): {user: $user, pass: $pass}}' \
     "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
}

function setup_haproxy() {
  local server_id="$1"
  local config_file="$CONFIG_DIR/$server_id/haproxy.cfg"
  
  log "[*] Setting up HAProxy for $server_id..."
  
  # Create HAProxy config
  cat > "$config_file" <<EOF
global
  log /dev/log local0
  daemon
  maxconn 2048

defaults
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
EOF

  # Add protocol configurations
  for proto in $(jq -r '.protocols | keys[]' "$CONFIG_DIR/$server_id/config.json"); do
    if [ "$(jq -r ".protocols.$proto.transport" "$CONFIG_DIR/$server_id/config.json")" == "haproxy" ]; then
      local port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
      
      cat >> "$config_file" <<EOF

frontend ${proto}_$server_id
  bind *:$port
  default_backend ${proto}_back_$server_id

backend ${proto}_back_$server_id
  mode tcp
  balance source
  stick-table type ip size 200k expire 30m
  stick on src
EOF

      while read -r ip; do
        echo "  server ${proto}_${ip//./_} $ip:$port check" >> "$config_file"
      done < <(jq -r '.foreign_servers | keys[]' "$CONFIG_DIR/$server_id/config.json")
    fi
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
  systemctl enable "haproxy-$server_id" >/dev/null 2>&1
  if ! systemctl start "haproxy-$server_id"; then
    log "[!] Failed to start HAProxy: $(systemctl status haproxy-$server_id | grep -i error)"
    return 1
  fi
  log "[+] HAProxy started successfully"
}

function setup_ipvs() {
  local server_id="$1"
  local proto="$2"
  local port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
  
  log "[*] Setting up IPVS for $proto on port $port..."
  
  # Clear existing rules
  ipvsadm -C
  
  # Add servers to IPVS
  while read -r ip; do
    ipvsadm -A -u ":$port" -s rr
    ipvsadm -a -u ":$port" -r "$ip:$port" -m
    log "[+] Added $ip:$port to IPVS"
  done < <(jq -r '.foreign_servers | keys[]' "$CONFIG_DIR/$server_id/config.json")
  
  # Make IPVS persistent
  cat > "/etc/systemd/system/ipvs-$server_id.service" <<EOF
[Unit]
Description=IPVS for $server_id
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipvsadm-restore < /etc/ipvs.rules
ExecStop=/sbin/ipvsadm -C

[Install]
WantedBy=multi-user.target
EOF

  ipvsadm-save > /etc/ipvs.rules
  systemctl daemon-reload
  systemctl enable "ipvs-$server_id" >/dev/null 2>&1
  systemctl start "ipvs-$server_id"
}

function configure_protocol() {
  local server_id="$1"
  local proto="$2"
  local port="$3"
  local transport="$4"
  
  log "[*] Configuring $proto on port $port using $transport..."
  
  # Update configuration
  jq --arg proto "$proto" \
     --arg port "$port" \
     --arg transport "$transport" \
     '.protocols += {($proto): {port: $port, transport: $transport}}' \
     "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
  
  # Apply configuration
  case "$transport" in
    "haproxy")
      setup_haproxy "$server_id"
      ;;
    "ipvs")
      setup_ipvs "$server_id" "$proto"
      ;;
    *)
      log "[!] Unknown transport: $transport"
      return 1
      ;;
  esac
}

function check_service_status() {
  local server_id="$1"
  echo -e "\n[+] Server Status: $server_id"
  
  # Check HAProxy
  if systemctl is-active "haproxy-$server_id" &>/dev/null; then
    echo " - HAProxy: ACTIVE"
    echo "   Listening ports:"
    ss -tlnp | grep "haproxy" | awk '{print "    - " $4}'
  else
    echo " - HAProxy: INACTIVE"
    echo "   Check logs: journalctl -u haproxy-$server_id -n 20 --no-pager"
  fi
  
  # Check IPVS
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
    echo "1) Add new server configuration"
    echo "2) Check server status"
    echo "3) Remove server configuration"
    echo "4) Exit"
    
    case $(get_input "Select option [1-4]: ") in
      1)
        # Get server name
        local server_name=$(get_input "Enter server name (e.g. iran1): ")
        local server_id="${server_name}-$(date +%s | head -c 6)"
        
        # Get Iranian server details
        echo "=== Iranian Server Configuration ==="
        local iran_ip=$(get_input "Enter Iranian server IP: ")
        local iran_user=$(get_input "Enter SSH username: ")
        local iran_pass=$(get_input "Enter SSH password: ")
        
        # Configure Iranian server
        configure_iran_server "$server_id" "$iran_ip" "$iran_user" "$iran_pass"
        
        # Get foreign servers
        echo "=== Foreign Servers Configuration ==="
        local domain=$(get_input "Enter foreign server domain (e.g. fo.xxxx.com): ")
        local servers=($(setup_dns_resolution "$domain"))
        
        if [ ${#servers[@]} -eq 0 ]; then
          log "[!] No servers found for domain $domain"
          pause
          continue
        fi
        
        # Get common foreign server credentials
        echo "Enter common credentials for all foreign servers:"
        local foreign_user=$(get_input "SSH username: ")
        local foreign_pass=$(get_input "SSH password: ")
        
        # Configure each foreign server
        for ip in "${servers[@]}"; do
          if ! configure_foreign_server "$server_id" "$ip" "$foreign_user" "$foreign_pass"; then
            log "[!] Failed to configure foreign server $ip"
          else
            log "[+] Successfully configured foreign server $ip"
          fi
        done
        
        # Configure protocols
        echo "=== Protocol Configuration ==="
        PROTOCOLS=(ssh vless vmess openvpn)
        for proto in "${PROTOCOLS[@]}"; do
          if [ "$(get_input "Enable $proto? [y/N]: " | tr '[:upper:]' '[:lower:]')" == "y" ]; then
            local port=$(get_input "Port for $proto: ")
            
            # Determine transport type
            local transport="haproxy"
            if [ "$proto" == "openvpn" ]; then
              transport="ipvs"
            else
              if [ "$(get_input "Use IPVS for $proto? (normally for UDP) [y/N]: " | tr '[:upper:]' '[:lower:]')" == "y" ]; then
                transport="ipvs"
              fi
            fi
            
            # Configure the protocol
            if ! configure_protocol "$server_id" "$proto" "$port" "$transport"; then
              log "[!] Failed to configure $proto"
            else
              log "[+] Successfully configured $proto on port $port using $transport"
            fi
          fi
        done
        
        check_service_status "$server_id"
        ;;
      2)
        if [ -z "$(ls -A "$CONFIG_DIR")" ]; then
          echo "No servers configured!"
        else
          select server in $(ls "$CONFIG_DIR"); do
            check_service_status "$server"
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
