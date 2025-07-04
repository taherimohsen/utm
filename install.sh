#!/bin/bash
# Ultimate UDP Tunnel Manager
# Version: 3.0
# GitHub: https://github.com/yourusername/udp-tunnel-manager

# Global Configuration
CONFIG_DIR="/etc/udp-tunnel"
LOG_DIR="/var/log/udp-tunnel"
LOCK_FILE="/var/run/udp-tunnel.lock"
SERVICE_NAME="udp-tunnel"
AUTO_RESTART_HOURS=12

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize
init_system() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    touch "$LOG_DIR/connections.log" "$LOG_DIR/error.log"
}

# Cleanup
clean_system() {
    echo -e "${YELLOW}Cleaning up existing installation...${NC}"
    
    # Stop and disable services
    systemctl stop "${SERVICE_NAME}-iran" 2>/dev/null
    systemctl stop "${SERVICE_NAME}-foreign" 2>/dev/null
    systemctl disable "${SERVICE_NAME}-iran" 2>/dev/null
    systemctl disable "${SERVICE_NAME}-foreign" 2>/dev/null
    
    # Remove files
    rm -f "/etc/systemd/system/${SERVICE_NAME}-iran.service"
    rm -f "/etc/systemd/system/${SERVICE_NAME}-foreign.service"
    rm -f "/usr/local/bin/${SERVICE_NAME}-manager"
    rm -rf "$CONFIG_DIR"
    rm -f "$LOCK_FILE"
    
    systemctl daemon-reload
    echo -e "${GREEN}Cleanup completed!${NC}"
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
Type=forking
ExecStart=/usr/local/bin/${SERVICE_NAME}-manager start iran
ExecStop=/usr/local/bin/${SERVICE_NAME}-manager stop iran
Restart=always
RestartSec=5s
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    # Enable auto-restart
    create_restart_timer

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-iran"
    
    echo -e "${GREEN}Iran server configured successfully!${NC}"
    echo -e "Use: systemctl start ${SERVICE_NAME}-iran"
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
Type=forking
ExecStart=/usr/local/bin/${SERVICE_NAME}-manager start foreign
ExecStop=/usr/local/bin/${SERVICE_NAME}-manager stop foreign
Restart=always
RestartSec=5s
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    # Enable auto-restart
    create_restart_timer

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-foreign"
    
    echo -e "${GREEN}Foreign server configured successfully!${NC}"
    echo -e "Use: systemctl start ${SERVICE_NAME}-foreign"
}

# Core Tunnel Functions
start_tunnel() {
    SERVER_TYPE="$1"
    CONFIG_FILE="$CONFIG_DIR/${SERVER_TYPE}.conf"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Config file not found!${NC}" | tee -a "$LOG_DIR/error.log"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    (
        flock -n 200 || exit 1
        
        echo "$(date) Starting ${SERVER_TYPE} tunnel on port ${LOCAL_PORT}" >> "$LOG_DIR/connections.log"
        
        if [[ $SERVER_TYPE == "iran" ]]; then
            for server in "${FOREIGN_SERVERS[@]}"; do
                socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$server:$LOCAL_PORT &
                echo "$(date) Connected to $server" >> "$LOG_DIR/connections.log"
            done
        else
            socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:127.0.0.1:$LOCAL_PORT &
        fi
        
        echo $! > "$LOCK_FILE"
        flock -u 200
    ) 200>"$LOCK_FILE"
}

stop_tunnel() {
    if [[ -f "$LOCK_FILE" ]]; then
        kill -9 $(cat "$LOCK_FILE") 2>/dev/null
        rm -f "$LOCK_FILE"
    fi
    pkill -f "socat.*$LOCAL_PORT"
    echo "$(date) Tunnel stopped" >> "$LOG_DIR/connections.log"
}

# Service Management
service_control() {
    ACTION="$1"
    SERVER_TYPE=$(detect_server_type)
    
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

# Auto-restart Configuration
create_restart_timer() {
    cat > "/etc/systemd/system/${SERVICE_NAME}-restart.timer" <<EOL
[Unit]
Description=Restart UDP Tunnel every ${AUTO_RESTART_HOURS} hours

[Timer]
OnBootSec=15min
OnUnitActiveSec=${AUTO_RESTART_HOURS}h

[Install]
WantedBy=timers.target
EOL

    cat > "/etc/systemd/system/${SERVICE_NAME}-restart.service" <<EOL
[Unit]
Description=Restart UDP Tunnel Service

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart ${SERVICE_NAME}-$(detect_server_type)
EOL

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-restart.timer"
    systemctl start "${SERVICE_NAME}-restart.timer"
}

# Status Monitoring
show_status() {
    SERVER_TYPE=$(detect_server_type)
    
    echo -e "\n${YELLOW}=== Service Status ==="
    systemctl status "${SERVICE_NAME}-${SERVER_TYPE}" --no-pager
    
    echo -e "\n=== Active Connections ==="
    ss -ulnp | grep -E "$LOCAL_PORT|socat"
    
    echo -e "\n=== Connection Logs ==="
    tail -n 10 "$LOG_DIR/connections.log"
}

# Helper Functions
detect_server_type() {
    if [[ -f "$CONFIG_DIR/iran.conf" ]]; then
        echo "iran"
    elif [[ -f "$CONFIG_DIR/foreign.conf" ]]; then
        echo "foreign"
    else
        echo ""
    fi
}

# Main Menu
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

# Installation
install_manager() {
    cp "$0" "/usr/local/bin/${SERVICE_NAME}-manager"
    chmod 755 "/usr/local/bin/${SERVICE_NAME}-manager"
    chown root:root "/usr/local/bin/${SERVICE_NAME}-manager"
}

# Main Execution
if [[ $1 == "core" ]]; then
    case $2 in
        "start")
            start_tunnel "$3"
            ;;
        "stop")
            stop_tunnel
            ;;
    esac
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
