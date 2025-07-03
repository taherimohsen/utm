#!/bin/bash
# UDP Tunnel Manager for OpenVPN
# Compatible with Ubuntu 22.04
# GitHub: https://github.com/yourusername/udp-tunnel-manager

# Configuration
CONFIG_DIR="/etc/udp-tunnel"
LOG_DIR="/var/log/udp-tunnel"
SERVICE_NAME="udp-tunnel"
RESTART_HOURS=12

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

## Main Functions ##

setup_iran() {
    echo -e "\n${BLUE}=== Iran Server Setup ===${NC}"
    
    read -p "Enter local UDP port (default 42347): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-42347}
    
    read -p "Enter foreign server IPs (comma separated): " FOREIGN_SERVERS
    
    # Save config
    cat > "$CONFIG_DIR/iran.conf" <<EOL
LOCAL_PORT=$LOCAL_PORT
FOREIGN_SERVERS=(${FOREIGN_SERVERS//,/ })
EOL

    # Create service file
    cat > "/etc/systemd/system/$SERVICE_NAME@iran.service" <<EOL
[Unit]
Description=UDP Tunnel Iran Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-tunnel core iran
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

    echo -e "${GREEN}Iran server configured!${NC}"
}

setup_foreign() {
    echo -e "\n${BLUE}=== Foreign Server Setup ===${NC}"
    
    read -p "Enter local UDP port (must match OpenVPN port): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-42347}
    
    read -p "Enter Iran server IP: " IRAN_SERVER
    
    # Save config
    cat > "$CONFIG_DIR/foreign.conf" <<EOL
LOCAL_PORT=$LOCAL_PORT
IRAN_SERVER=$IRAN_SERVER
EOL

    # Configure NAT rules
    configure_nat

    # Create service file
    cat > "/etc/systemd/system/$SERVICE_NAME@foreign.service" <<EOL
[Unit]
Description=UDP Tunnel Foreign Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-tunnel core foreign
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

    echo -e "${GREEN}Foreign server configured!${NC}"
}

configure_nat() {
    # Setup NAT for port sharing
    iptables -t nat -A PREROUTING -p udp --dport $LOCAL_PORT -j REDIRECT --to-port $LOCAL_PORT
    iptables -A INPUT -p udp --dport $LOCAL_PORT -j ACCEPT
    
    # Save rules
    apt-get install -y iptables-persistent
    netfilter-persistent save
}

core_tunnel() {
    SERVER_TYPE=$1
    source "$CONFIG_DIR/${SERVER_TYPE}.conf"
    
    if [[ $SERVER_TYPE == "iran" ]]; then
        # Iran server connects to multiple foreign servers
        while true; do
            for server in "${FOREIGN_SERVERS[@]}"; do
                socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$server:$LOCAL_PORT &
            done
            wait
            sleep 5
        done
    else
        # Foreign server handles port sharing
        while true; do
            socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:127.0.0.1:$LOCAL_PORT
            sleep 5
        done
    fi
}

## Management Functions ##

start_service() {
    SERVER_TYPE=$(get_server_type)
    systemctl enable "$SERVICE_NAME@$SERVER_TYPE"
    systemctl start "$SERVICE_NAME@$SERVER_TYPE"
    echo -e "${GREEN}Service started!${NC}"
}

stop_service() {
    SERVER_TYPE=$(get_server_type)
    systemctl stop "$SERVICE_NAME@$SERVER_TYPE"
    systemctl disable "$SERVICE_NAME@$SERVER_TYPE"
    echo -e "${RED}Service stopped!${NC}"
}

check_status() {
    SERVER_TYPE=$(get_server_type)
    echo -e "\n${YELLOW}=== Service Status ==="
    systemctl status "$SERVICE_NAME@$SERVER_TYPE" --no-pager
    
    echo -e "\n=== Port Usage ==="
    ss -ulnp | grep -E "$LOCAL_PORT|socat"
    
    echo -e "\n=== Connection Count ==="
    netstat -anup | grep "$LOCAL_PORT"
}

## Helper Functions ##

get_server_type() {
    [[ -f "$CONFIG_DIR/iran.conf" ]] && echo "iran" || echo "foreign"
}

show_menu() {
    clear
    echo -e "${YELLOW}=== UDP Tunnel Manager ==="
    echo -e "1. Setup Iran Server"
    echo -e "2. Setup Foreign Server"
    echo -e "3. Start Tunnel"
    echo -e "4. Stop Tunnel"
    echo -e "5. Check Status"
    echo -e "6. Exit${NC}"
    echo -n "Select option: "
}

## Main Execution ##

case "$1" in
    "core")
        core_tunnel "$2"
        ;;
    *)
        while true; do
            show_menu
            read choice
            
            case $choice in
                1) setup_iran ;;
                2) setup_foreign ;;
                3) start_service ;;
                4) stop_service ;;
                5) check_status ;;
                6) exit 0 ;;
                *) echo -e "${RED}Invalid option!${NC}" ;;
            esac
            
            read -p "Press Enter to continue..."
        done
        ;;
esac
