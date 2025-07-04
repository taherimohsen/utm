#!/bin/bash
# Ultimate UDP Tunnel Manager - Fixed Version
# GitHub: https://github.com/yourusername/udp-tunnel-manager
# Version: 4.0

# Global Configuration
CONFIG_DIR="/etc/udp-tunnel"
LOG_DIR="/var/log/udp-tunnel"
LOCK_FILE="/var/run/udp-tunnel.lock"
SERVICE_NAME="udp-tunnel"
SCRIPT_NAME="udp-tunnel-manager"
SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize system
init_system() {
    echo -e "${YELLOW}Initializing system...${NC}"
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    touch "$LOG_DIR/connections.log" "$LOG_DIR/error.log"
    chmod 644 "$LOG_DIR"/*.log
}

# Cleanup existing installation
clean_system() {
    echo -e "${YELLOW}Cleaning up existing installation...${NC}"
    
    systemctl stop "${SERVICE_NAME}-iran" 2>/dev/null
    systemctl stop "${SERVICE_NAME}-foreign" 2>/dev/null
    systemctl disable "${SERVICE_NAME}-iran" 2>/dev/null
    systemctl disable "${SERVICE_NAME}-foreign" 2>/dev/null
    
    rm -f "/etc/systemd/system/${SERVICE_NAME}-iran.service"
    rm -f "/etc/systemd/system/${SERVICE_NAME}-foreign.service"
    rm -f "$SCRIPT_PATH"
    rm -f "$LOCK_FILE"
    
    systemctl daemon-reload
    echo -e "${GREEN}Cleanup completed!${NC}"
}

# Install the manager script
install_manager() {
    echo -e "${YELLOW}Installing manager script...${NC}"
    cp "$0" "$SCRIPT_PATH"
    chmod 755 "$SCRIPT_PATH"
    chown root:root "$SCRIPT_PATH"
    echo -e "${GREEN}Manager script installed to ${SCRIPT_PATH}${NC}"
}

# Iran Server Setup
setup_iran() {
    clean_system
    init_system
    
    echo -e "\n${BLUE}=== Iran Server Configuration ===${NC}"
    
    read -p "Enter local UDP port (default 42347): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-42347}
    
    read -p "Enter foreign server IPs (comma separated): " FOREIGN_SERVERS
    
    # Save config
    cat > "$CONFIG_DIR/iran.conf" <<EOL
LOCAL_PORT=$LOCAL_PORT
FOREIGN_SERVERS=(${FOREIGN_SERVERS//,/ })
EOL

    # Create service file
    cat > "/etc/systemd/system/${SERVICE_NAME}-iran.service" <<EOL
[Unit]
Description=UDP Tunnel Iran Service
After=network.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} run iran
Restart=always
RestartSec=5s
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-iran"
    
    echo -e "${GREEN}Iran server configured successfully!${NC}"
    echo -e "Start service with: systemctl start ${SERVICE_NAME}-iran"
}

# Foreign Server Setup
setup_foreign() {
    clean_system
    init_system
    
    echo -e "\n${BLUE}=== Foreign Server Configuration ===${NC}"
    
    read -p "Enter local UDP port (must match OpenVPN port): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-42347}
    
    # Configure NAT
    echo -e "${YELLOW}Configuring NAT rules...${NC}"
    apt-get install -y iptables-persistent
    iptables -t nat -A PREROUTING -p udp --dport $LOCAL_PORT -j REDIRECT --to-port $LOCAL_PORT
    iptables -A INPUT -p udp --dport $LOCAL_PORT -j ACCEPT
    netfilter-persistent save
    
    # Save config
    cat > "$CONFIG_DIR/foreign.conf" <<EOL
LOCAL_PORT=$LOCAL_PORT
EOL

    # Create service file
    cat > "/etc/systemd/system/${SERVICE_NAME}-foreign.service" <<EOL
[Unit]
Description=UDP Tunnel Foreign Service
After=network.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} run foreign
Restart=always
RestartSec=5s
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-foreign"
    
    echo -e "${GREEN}Foreign server configured successfully!${NC}"
    echo -e "Start service with: systemctl start ${SERVICE_NAME}-foreign"
}

# Core tunnel function
run_tunnel() {
    SERVER_TYPE="$1"
    CONFIG_FILE="$CONFIG_DIR/${SERVER_TYPE}.conf"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Config file not found!${NC}" | tee -a "$LOG_DIR/error.log"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    echo "$(date) Starting ${SERVER_TYPE} tunnel on port ${LOCAL_PORT}" >> "$LOG_DIR/connections.log"
    
    if [[ $SERVER_TYPE == "iran" ]]; then
        for server in "${FOREIGN_SERVERS[@]}"; do
            socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$server:$LOCAL_PORT &
            echo "$(date) Connected to $server" >> "$LOG_DIR/connections.log"
        done
    else
        socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:127.0.0.1:$LOCAL_PORT &
    fi
    
    wait
}

# Service control
service_control() {
    ACTION="$1"
    SERVER_TYPE=$(detect_server_type)
    
    if [[ -z "$SERVER_TYPE" ]]; then
        echo -e "${RED}Error: Server type not detected!${NC}"
        return 1
    fi
    
    case $ACTION in
        "start")
            systemctl start "${SERVICE_NAME}-${SERVER_TYPE}"
            ;;
        "stop")
            systemctl stop "${SERVICE_NAME}-${SERVER_TYPE}"
            ;;
        "restart")
            systemctl restart "${SERVICE_NAME}-${SERVER_TYPE}"
            ;;
        "status")
            show_status
            ;;
    esac
}

# Show service status
show_status() {
    SERVER_TYPE=$(detect_server_type)
    
    echo -e "\n${YELLOW}=== Service Status ==="
    systemctl status "${SERVICE_NAME}-${SERVER_TYPE}" --no-pager
    
    echo -e "\n=== Active Connections ==="
    ss -ulnp | grep -E "${LOCAL_PORT}|socat"
    
    echo -e "\n=== Connection Logs ==="
    tail -n 10 "$LOG_DIR/connections.log"
    
    echo -e "\n=== Error Logs ==="
    tail -n 10 "$LOG_DIR/error.log"
}

# Detect server type
detect_server_type() {
    if [[ -f "$CONFIG_DIR/iran.conf" ]]; then
        echo "iran"
    elif [[ -f "$CONFIG_DIR/foreign.conf" ]]; then
        echo "foreign"
    else
        echo ""
    fi
}

# Main menu
main_menu() {
    clear
    echo -e "${YELLOW}=== Ultimate UDP Tunnel Manager ==="
    echo -e "1. Setup Iran Server"
    echo -e "2. Setup Foreign Server"
    echo -e "3. Start Tunnel Service"
    echo -e "4. Stop Tunnel Service"
    echo -e "5. Restart Tunnel Service"
    echo -e "6. Check Service Status"
    echo -e "7. Uninstall Everything"
    echo -e "8. Exit${NC}"
    echo -n "Select option: "
}

# Main execution
if [[ "$1" == "run" ]]; then
    run_tunnel "$2"
else
    install_manager
    
    while true; do
        main_menu
        read choice
        
        case $choice in
            1) setup_iran ;;
            2) setup_foreign ;;
            3) service_control "start" ;;
            4) service_control "stop" ;;
            5) service_control "restart" ;;
            6) service_control "status" ;;
            7) clean_system ;;
            8) exit 0 ;;
            *) echo -e "${RED}Invalid option!${NC}" ;;
        esac
        
        read -p "Press Enter to continue..."
    done
fi
