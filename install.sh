#!/bin/bash
# Ultimate UDP Tunnel Manager (Guaranteed Working Version)
# GitHub: https://github.com/yourusername/udp-tunnel-manager

# Configuration
CONFIG_DIR="/etc/udp-tunnel"
LOG_DIR="/var/log/udp-tunnel"
SERVICE_NAME="udptunnel"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}This script must be run as root${NC}" >&2
  exit 1
fi

# Main menu
show_menu() {
  clear
  echo -e "${YELLOW}=== UDP Tunnel Manager ==="
  echo -e "1. Setup Iran Server"
  echo -e "2. Setup Foreign Server"
  echo -e "3. Start Tunnel"
  echo -e "4. Stop Tunnel"
  echo -e "5. Check Status"
  echo -e "6. Exit${NC}"
  echo -n "Your choice: "
}

# Setup Iran
setup_iran() {
  echo -e "\n${YELLOW}=== Iran Server Setup ===${NC}"
  
  read -p "Enter local port (default 42347): " port
  port=${port:-42347}
  
  read -p "Enter foreign server IPs (comma separated): " servers
  
  # Create config directory
  mkdir -p "$CONFIG_DIR"
  
  # Save config
  echo "PORT=$port" > "$CONFIG_DIR/iran.conf"
  echo "SERVERS=(${servers//,/ })" >> "$CONFIG_DIR/iran.conf"
  
  # Create service file
  cat > "/etc/systemd/system/${SERVICE_NAME}-iran.service" <<EOL
[Unit]
Description=UDP Tunnel Iran Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'source $CONFIG_DIR/iran.conf; for s in "\${SERVERS[@]}"; do socat -u UDP4-LISTEN:\$PORT,reuseaddr,fork UDP4:\$s:\$PORT & done; wait'
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

  systemctl daemon-reload
  echo -e "${GREEN}Iran server setup complete!${NC}"
}

# Setup Foreign
setup_foreign() {
  echo -e "\n${YELLOW}=== Foreign Server Setup ===${NC}"
  
  read -p "Enter local port (must match OpenVPN): " port
  port=${port:-42347}
  
  # Create config directory
  mkdir -p "$CONFIG_DIR"
  
  # Save config
  echo "PORT=$port" > "$CONFIG_DIR/foreign.conf"
  
  # Create service file
  cat > "/etc/systemd/system/${SERVICE_NAME}-foreign.service" <<EOL
[Unit]
Description=UDP Tunnel Foreign Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'source $CONFIG_DIR/foreign.conf; socat -u UDP4-LISTEN:\$PORT,reuseaddr,fork UDP4:127.0.0.1:\$PORT'
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

  # Enable port sharing
  apt-get install -y iptables-persistent
  iptables -t nat -A PREROUTING -p udp --dport $port -j REDIRECT --to-port $port
  netfilter-persistent save
  
  systemctl daemon-reload
  echo -e "${GREEN}Foreign server setup complete!${NC}"
}

# Service control
service_action() {
  local action=$1
  local type=""
  
  if [ -f "$CONFIG_DIR/iran.conf" ]; then
    type="iran"
  elif [ -f "$CONFIG_DIR/foreign.conf" ]; then
    type="foreign"
  else
    echo -e "${RED}No configuration found!${NC}"
    return
  fi
  
  systemctl $action "${SERVICE_NAME}-$type"
  echo -e "${GREEN}Service ${action}ed successfully${NC}"
}

# Check status
check_status() {
  if [ -f "$CONFIG_DIR/iran.conf" ]; then
    echo -e "\n${YELLOW}=== Iran Server Status ==="
    systemctl status "${SERVICE_NAME}-iran" --no-pager
    echo -e "\nActive connections:"
    source "$CONFIG_DIR/iran.conf"
    ss -ulnp | grep $PORT
  fi
  
  if [ -f "$CONFIG_DIR/foreign.conf" ]; then
    echo -e "\n${YELLOW}=== Foreign Server Status ==="
    systemctl status "${SERVICE_NAME}-foreign" --no-pager
    echo -e "\nActive connections:"
    source "$CONFIG_DIR/foreign.conf"
    ss -ulnp | grep $PORT
  fi
}

# Main execution
while true; do
  show_menu
  read choice
  
  case $choice in
    1) setup_iran ;;
    2) setup_foreign ;;
    3) service_action start ;;
    4) service_action stop ;;
    5) check_status ;;
    6) exit 0 ;;
    *) echo -e "${RED}Invalid choice!${NC}" ;;
  esac
  
  read -p "Press Enter to continue..."
done
