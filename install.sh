#!/bin/bash
# Ultimate Tunnel Manager - Fixed Version
set -euo pipefail

# Configurations
CONFIG_DIR="/etc/utm"
LOG_DIR="/var/log/utm"

# Initialize directories
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

function show_header() {
  clear
  echo "========================================"
  echo "  Ultimate Tunnel Manager (Fixed)"
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
  dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
}

function configure_haproxy() {
  local server_id="$1"
  local config_file="$CONFIG_DIR/$server_id/haproxy.cfg"
  
  # Check if HAProxy is installed
  if ! command -v haproxy &> /dev/null; then
    echo "[!] HAProxy is not installed. Installing..."
    apt-get update && apt-get install -y haproxy
  fi

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
      done < <(jq -r '.servers[]' "$CONFIG_DIR/$server_id/config.json")
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
  systemctl enable --now "haproxy-$server_id" > "$LOG_DIR/haproxy-$server_id.log" 2>&1
}

function configure_ipvs() {
  local server_id="$1"
  local proto="$2"
  local port=$(jq -r ".protocols.$proto.port" "$CONFIG_DIR/$server_id/config.json")
  
  # Check if IPVS is available
  if ! command -v ipvsadm &> /dev/null; then
    echo "[!] IPVS tools not installed. Installing..."
    apt-get update && apt-get install -y ipvsadm
  fi

  # Clear existing rules
  ipvsadm -C

  # Add servers to IPVS
  while read -r ip; do
    ipvsadm -A -u ":$port" -s rr
    ipvsadm -a -u ":$port" -r "$ip:$port" -m
  done < <(jq -r '.servers[]' "$CONFIG_DIR/$server_id/config.json")
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
    echo "   Configuration:"
    grep -E 'frontend|backend' "$CONFIG_DIR/$server_id/haproxy.cfg" | sed 's/^/    /'
  else
    echo " - HAProxy: INACTIVE (check logs in $LOG_DIR/haproxy-$server_id.log)"
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
        
        if [ ${#servers[@]} -eq 0 ]; then
          echo "[!] No servers found for domain $domain"
          pause
          continue
        fi
        
        # Get common credentials
        echo "Enter common credentials for all servers:"
        local common_user=$(get_input "Username: ")
        local common_pass=$(get_input "Password: ")
        
        # Save configuration
        jq -n \
          --arg domain "$domain" \
          --argjson servers "$(printf '%s\n' "${servers[@]}" | jq -R . | jq -s .)" \
          --arg common_user "$common_user" \
          --arg common_pass "$common_pass" \
          '{
            domain: $domain,
            servers: $servers,
            common_credentials: {
              user: $common_user,
              pass: $common_pass
            },
            protocols: {}
          }' > "$CONFIG_DIR/$server_id/config.json"
        
        # Configure protocols
        PROTOCOLS=(ssh vless vmess openvpn)
        for proto in "${PROTOCOLS[@]}"; do
          if [ "$(get_input "Enable $proto? [y/N]: " | tr '[:upper:]' '[:lower:]')" == "y" ]; then
            local port=$(get_input "Port for $proto: ")
            
            # Ask for transport type
            local transport="haproxy"
            if [ "$proto" == "openvpn" ]; then
              transport="ipvs"
            else
              if [ "$(get_input "Use IPVS for $proto? (normally for UDP) [y/N]: " | tr '[:upper:]' '[:lower:]')" == "y" ]; then
                transport="ipvs"
              fi
            fi
            
            jq --arg proto "$proto" \
               --arg port "$port" \
               --arg transport "$transport" \
               '.protocols += {($proto): {port: $port, transport: $transport}}' \
               "$CONFIG_DIR/$server_id/config.json" > tmp.json && mv tmp.json "$CONFIG_DIR/$server_id/config.json"
            
            # Immediately configure the protocol
            if [ "$transport" == "ipvs" ]; then
              configure_ipvs "$server_id" "$proto"
            fi
          fi
        done
        
        # Apply configurations
        configure_haproxy "$server_id"
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
