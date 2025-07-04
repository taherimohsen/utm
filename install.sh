#!/bin/bash
# Ultimate UDP Tunnel Manager (All-in-One Version)
# GitHub: https://github.com/yourusername/udp-tunnel-manager

# Configuration
CONFIG_DIR="/etc/udp-tunnel"
LOG_FILE="/var/log/udp-tunnel.log"
SERVICE_NAME="udp-tunnel"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize
init_system() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# Clean Installation
clean_installation() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
}

# Setup Tunnel
setup_tunnel() {
    clean_installation
    init_system
    
    echo -e "\n${BLUE}=== Tunnel Setup ===${NC}"
    
    read -p "Enter local UDP port (default 42347): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-42347}
    
    read -p "Is this the Iran server? (y/n): " IS_IRAN
    
    if [[ "$IS_IRAN" =~ ^[Yy] ]]; then
        read -p "Enter foreign server IPs (comma separated): " FOREIGN_SERVERS
        echo "LOCAL_PORT=$LOCAL_PORT" > "$CONFIG_DIR/config"
        echo "FOREIGN_SERVERS=(${FOREIGN_SERVERS//,/ })" >> "$CONFIG_DIR/config"
        echo "SERVER_TYPE=iran" >> "$CONFIG_DIR/config"
    else
        # Foreign server setup
        apt-get install -y iptables-persistent socat
        iptables -t nat -A PREROUTING -p udp --dport $LOCAL_PORT -j REDIRECT --to-port $LOCAL_PORT
        iptables -A INPUT -p udp --dport $LOCAL_PORT -j ACCEPT
        netfilter-persistent save
        
        echo "LOCAL_PORT=$LOCAL_PORT" > "$CONFIG_DIR/config"
        echo "SERVER_TYPE=foreign" >> "$CONFIG_DIR/config"
    fi

    # Create service file
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOL
[Unit]
Description=UDP Tunnel Service
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONFIG_DIR/config
ExecStart=/bin/bash -c 'if [ "\$SERVER_TYPE" == "iran" ]; then for s in "\${FOREIGN_SERVERS[@]}"; do socat -u UDP4-LISTEN:\$LOCAL_PORT,reuseaddr,fork UDP4:\$s:\$LOCAL_PORT & done; wait; else socat -u UDP4-LISTEN:\$LOCAL_PORT,reuseaddr,fork UDP4:127.0.0.1:\$LOCAL_PORT; fi'
Restart=always
RestartSec=5s
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    echo -e "${GREEN}Setup completed!${NC}"
    echo -e "Start service with: systemctl start $SERVICE_NAME"
}

# Service Control
service_control() {
    case "$1" in
        "start")
            systemctl start "$SERVICE_NAME"
            ;;
        "stop")
            systemctl stop "$SERVICE_NAME"
            ;;
        "restart")
            systemctl restart "$SERVICE_NAME"
            ;;
    esac
    systemctl status "$SERVICE_NAME" --no-pager
}

# Main Menu
main_menu() {
    clear
    echo -e "${YELLOW}=== UDP Tunnel Manager ==="
    echo -e "1. Setup Tunnel"
    echo -e "2. Start Tunnel"
    echo -e "3. Stop Tunnel"
    echo -e "4. Restart Tunnel"
    echo -e "5. Check Status"
    echo -e "6. Uninstall"
    echo -e "7. Exit${NC}"
    echo -n "Your choice: "
}

# Ensure root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}" >&2
    exit 1
fi

# Main Execution
while true; do
    main_menu
    read choice
    
    case $choice in
        1) setup_tunnel ;;
        2) service_control "start" ;;
        3) service_control "stop" ;;
        4) service_control "restart" ;;
        5) systemctl status "$SERVICE_NAME" --no-pager ;;
        6) clean_installation ;;
        7) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
    
    read -p "Press Enter to continue..."
done
