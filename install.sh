#!/bin/bash
# UDP Tunnel Manager for OpenVPN
# GitHub: https://github.com/yourusername/udp-tunnel-manager
# License: MIT

# Configuration
CONFIG_DIR="/etc/udp-tunnel"
LOG_DIR="/var/log/udp-tunnel"
SERVICE_NAME="udp-tunnel"
RESTART_HOURS=12  # Auto-restart interval in hours

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

# Main Menu
main_menu() {
    clear
    echo -e "${YELLOW}=== UDP Tunnel Manager ==="
    echo -e "1. Setup Iran Server"
    echo -e "2. Setup Foreign Server"
    echo -e "3. Start Tunnel"
    echo -e "4. Stop Tunnel"
    echo -e "5. Check Status"
    echo -e "6. Set Auto-Restart"
    echo -e "7. Uninstall"
    echo -e "8. Exit${NC}"
    echo -n "Select option: "
}

# Iran Server Setup
setup_iran() {
    echo -e "\n${BLUE}=== Iran Server Setup ===${NC}"
    
    read -p "Enter local UDP port (default 1194): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-1194}
    
    read -p "Enter foreign server addresses (comma separated): " FOREIGN_SERVERS
    
    # Save config
    mkdir -p "$CONFIG_DIR"
    echo "LOCAL_PORT=$LOCAL_PORT" > "$CONFIG_DIR/iran.conf"
    echo "FOREIGN_SERVERS=(${FOREIGN_SERVERS//,/ })" >> "$CONFIG_DIR/iran.conf"
    
    # Create tunnel script
    cat > "/usr/local/bin/udp-tunnel-iran.sh" <<'EOL'
#!/bin/bash
# Tunnel script for Iran server

CONFIG="$CONFIG_DIR/iran.conf"
LOG="$LOG_DIR/iran.log"

source "$CONFIG"

while true; do
    for server in "${FOREIGN_SERVERS[@]}"; do
        socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$server:$LOCAL_PORT &
    done
    wait
    sleep 5
done
EOL

    chmod +x "/usr/local/bin/udp-tunnel-iran.sh"
    
    # Create systemd service
    cat > "/etc/systemd/system/$SERVICE_NAME@iran.service" <<EOL
[Unit]
Description=UDP Tunnel Iran Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-tunnel-iran.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

    echo -e "${GREEN}Iran server setup completed!${NC}"
}

# Foreign Server Setup
setup_foreign() {
    echo -e "\n${BLUE}=== Foreign Server Setup ===${NC}"
    
    read -p "Enter local UDP port (default 1194): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-1194}
    
    read -p "Enter Iran server address: " IRAN_SERVER
    
    # Save config
    mkdir -p "$CONFIG_DIR"
    echo "LOCAL_PORT=$LOCAL_PORT" > "$CONFIG_DIR/foreign.conf"
    echo "IRAN_SERVER=$IRAN_SERVER" >> "$CONFIG_DIR/foreign.conf"
    
    # Create tunnel script
    cat > "/usr/local/bin/udp-tunnel-foreign.sh" <<'EOL'
#!/bin/bash
# Tunnel script for Foreign server

CONFIG="$CONFIG_DIR/foreign.conf"
LOG="$LOG_DIR/foreign.log"

source "$CONFIG"

while true; do
    socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$IRAN_SERVER:$LOCAL_PORT
    sleep 5
done
EOL

    chmod +x "/usr/local/bin/udp-tunnel-foreign.sh"
    
    # Create systemd service
    cat > "/etc/systemd/system/$SERVICE_NAME@foreign.service" <<EOL
[Unit]
Description=UDP Tunnel Foreign Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-tunnel-foreign.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

    echo -e "${GREEN}Foreign server setup completed!${NC}"
}

# Start Tunnel
start_tunnel() {
    SERVER_TYPE=$(get_server_type)
    
    if [[ -z "$SERVER_TYPE" ]]; then
        echo -e "${RED}Server not configured! Run setup first.${NC}"
        return
    fi
    
    systemctl enable "$SERVICE_NAME@$SERVER_TYPE"
    systemctl start "$SERVICE_NAME@$SERVER_TYPE"
    
    echo -e "${GREEN}Tunnel started successfully!${NC}"
}

# Stop Tunnel
stop_tunnel() {
    SERVER_TYPE=$(get_server_type)
    
    if [[ -z "$SERVER_TYPE" ]]; then
        echo -e "${RED}Server not configured!${NC}"
        return
    fi
    
    systemctl stop "$SERVICE_NAME@$SERVER_TYPE"
    systemctl disable "$SERVICE_NAME@$SERVER_TYPE"
    
    echo -e "${RED}Tunnel stopped!${NC}"
}

# Check Status
check_status() {
    SERVER_TYPE=$(get_server_type)
    
    if [[ -z "$SERVER_TYPE" ]]; then
        echo -e "${RED}Server not configured!${NC}"
        return
    fi
    
    echo -e "\n${YELLOW}=== Tunnel Status ==="
    systemctl status "$SERVICE_NAME@$SERVER_TYPE" --no-pager
    echo -e "===================${NC}"
    
    echo -e "\n${YELLOW}=== Active Connections ==="
    ss -ulnp | grep -E "socat|$SERVICE_NAME"
    echo -e "=======================${NC}"
}

# Set Auto-Restart
set_autorestart() {
    read -p "Enter restart interval in hours (default 12): " INTERVAL
    INTERVAL=${INTERVAL:-12}
    
    # Create restart timer
    cat > "/etc/systemd/system/udp-tunnel-restart.timer" <<EOL
[Unit]
Description=Restart UDP Tunnel every $INTERVAL hours

[Timer]
OnBootSec=15min
OnUnitActiveSec=${INTERVAL}h

[Install]
WantedBy=timers.target
EOL

    # Create restart service
    cat > "/etc/systemd/system/udp-tunnel-restart.service" <<EOL
[Unit]
Description=Restart UDP Tunnel Service

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart $SERVICE_NAME@$(get_server_type)
EOL

    systemctl daemon-reload
    systemctl enable udp-tunnel-restart.timer
    systemctl start udp-tunnel-restart.timer
    
    echo -e "${GREEN}Auto-restart every $INTERVAL hours configured!${NC}"
}

# Uninstall
uninstall() {
    stop_tunnel
    
    rm -rf "$CONFIG_DIR"
    rm -f "/usr/local/bin/udp-tunnel-iran.sh"
    rm -f "/usr/local/bin/udp-tunnel-foreign.sh"
    rm -f "/etc/systemd/system/$SERVICE_NAME@*"
    rm -f "/etc/systemd/system/udp-tunnel-restart.*"
    
    systemctl daemon-reload
    
    echo -e "${GREEN}UDP Tunnel completely uninstalled!${NC}"
}

# Helper function to detect server type
get_server_type() {
    if [[ -f "$CONFIG_DIR/iran.conf" ]]; then
        echo "iran"
    elif [[ -f "$CONFIG_DIR/foreign.conf" ]]; then
        echo "foreign"
    else
        echo ""
    fi
}

# Main loop
while true; do
    main_menu
    read choice
    
    case $choice in
        1) setup_iran ;;
        2) setup_foreign ;;
        3) start_tunnel ;;
        4) stop_tunnel ;;
        5) check_status ;;
        6) set_autorestart ;;
        7) uninstall ;;
        8) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
    
    read -p "Press Enter to continue..."
done
