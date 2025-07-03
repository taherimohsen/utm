#!/bin/bash
# Ultimate Tunnel Manager - Complete Version
set -euo pipefail

# Configurations
CONFIG_DIR="/etc/utm"
LOG_DIR="/var/log/utm"

# Initialize directories
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

function show_header() {
  clear
  echo "========================================"
  echo "  Ultimate Tunnel Manager (Complete)"
  echo "========================================"
}

function pause() {
  read -rp "Press Enter to continue..."
}

function get_input() {
  read -rp "$1" input
  echo "$input"
}

function setup_dns_resolution() {
  local domain="$1"
  echo "[*] Resolving $domain..."
  dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+'
}

function configure_haproxy() {
  local server_id="$1"
  local config_file="$CONFIG_DIR/$server_id/haproxy.cfg"
  
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
  systemctl enable --now "haproxy-$server_id"
}

function remove_server() {
  local server_id="$1"
  
  echo "[*] Removing server $server_id..."
  
  # Stop and disable services
  systemctl stop "haproxy-$server_id" 2>/dev/null || true
  systemctl disable "haproxy-$server_id" 2>/dev/null || true
  
  # Remove configuration files
  rm -f "/etc/systemd/system/haproxy-$server_id.service"
  rm -rf "$CONFIG_DIR/$server_id"
  
  systemctl daemon-reload
  echo "[+] Server $server_id removed successfully"
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
  fi
  
  # Check IPVS
  local ipvs_active=0
  for proto in $(jq -r '.protocols | keys[]' "$CONFIG_DIR/$server_id/config.json"); do
    if [ "$(jq -r ".protocols.$proto.transport" "$CONFIG_DIR/$server_id/config.json")" == "ipvs" ]; then
      ipvs_active=1
      if ipvsadm -ln | grep -q "$proto"; then
        echo " - IPVS ($proto): ACTIVE"
      else
        echo " - IPVS ($proto): INACTIVE"
      fi
    fi
  done
  
  [ $ipvs_active -eq 0 ] && echo " - IPVS: No UDP protocols configured"
}

function main_menu() {
  while true; do
    show_header
    echo "1) Add new Iranian server"
    echo "2) Check server status"
    echo "3) Remove server"
    echo "4) Exit"
    
    case $(get_input "Select option [1-4]: ") in
      1)
        local server_name=$(get_input "Enter server name (e.g. iran1): ")
        local server_id="${server_name}-$(date +%s | head -c 6)"
        mkdir -p "$CONFIG_DIR/$server_id"
        
        # Get foreign servers
        local domain=$(get_input "Enter foreign server domain (e.g. fo.xxxx.com): ")
        mapfile -t servers < <(setup_dns_resolution "$domain")
        
        # Get credentials for each server
        declare -A credentials
        for ip in "${servers[@]}"; do
          echo "Enter credentials for $ip:"
          credentials[$ip]="$(get_input "Username: "):$(get_input "Password: ")"
        done
        
        # Save configuration
        jq -n \
          --arg domain "$domain" \
          --argjson servers "$(printf '%s\n' "${servers[@]}" | jq -R . | jq -s .)" \
          --argjson creds "$(for ip in "${!credentials[@]}"; do echo "$ip:${credentials[$ip]}"; done | jq -R . | jq -s . | jq 'map(split(":")) | map({(.[0]): {user: .[1], pass: .[2]}}) | add')" \
          '{
            domain: $domain,
            servers: $servers,
            foreign_servers: $creds,
            protocols: {}
          }' > "$CONFIG_DIR/$server_id/config.json"
        
        # Configure protocols
        PROTOCOLS=(ssh vless vmess openvpn)
        for proto in "${PROTOCOLS[@]}"; do
          if [ "$(get_input "Enable $proto? [y/N]: ")" == "y" ]; then
            local port=$(get_input "Port for $proto: ")
            local transport=$([ "$proto" == "openvpn" ] && echo "ipvs" || echo "haproxy")
            
            jq --arg proto "$proto" \
               --arg port "$port" \
               --arg transport "$transport" \
               '.protocols += {($proto): {port: $port, transport: $transport}}' \
               "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
          fi
        done
        
        # Apply configurations
        configure_haproxy "$server_id"
        check_service_status "$server_id"
        ;;
      2)
        if [ -z "$(ls "$CONFIG_DIR")" ]; then
          echo "No servers configured!"
        else
          select server in $(ls "$CONFIG_DIR"); do
            check_service_status "$server"
            break
          done
        fi
        ;;
      3)
        if [ -z "$(ls "$CONFIG_DIR")" ]; then
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
