#!/bin/bash
# Advanced UDP Tunnel Manager
# GitHub: https://github.com/yourusername/udp-tunnel-manager
# License: MIT

# Configuration
CONFIG_DIR="/etc/udp-tunnel"
LOG_DIR="/var/log/udp-tunnel"
SERVICE_NAME="udp-tunnel"
LOCK_FILE="/var/run/udp-tunnel.lock"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
touch "$LOG_DIR/connections.log"

### Core Functions ###

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
    cat > "/etc/systemd/system/${SERVICE_NAME}-iran.service" <<EOL
[Unit]
Description=UDP Tunnel Iran Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-tunnel-manager start iran
ExecStop=/usr/local/bin/udp-tunnel-manager stop iran
Restart=always
RestartSec=5s
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    echo -e "${GREEN}Iran server configured successfully!${NC}"
}

setup_foreign() {
    echo -e "\n${BLUE}=== Foreign Server Setup ===${NC}"
    
    read -p "Enter local UDP port (must match OpenVPN port): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-42347}
    
    # Configure NAT
    apt-get install -y iptables-persistent
    iptables -t nat -A PREROUTING -p udp --dport $LOCAL_PORT -j REDIRECT --to-port $LOCAL_PORT
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
ExecStart=/usr/local/bin/udp-tunnel-manager start foreign
ExecStop=/usr/local/bin/udp-tunnel-manager stop foreign
Restart=always
RestartSec=5s
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    echo -e "${GREEN}Foreign server configured successfully!${NC}"
}

start_tunnel() {
    SERVER_TYPE=$1
    source "$CONFIG_DIR/${SERVER_TYPE}.conf"
    
    (
        flock -n 200 || exit 1
        
        if [[ $SERVER_TYPE == "iran" ]]; then
            # Start multiple tunnels for each foreign server
            for server in "${FOREIGN_SERVERS[@]}"; do
                socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$server:$LOCAL_PORT &
                echo "$(date): Connected to $server" >> "$LOG_DIR/connections.log"
            done
        else
            # Foreign server with port sharing
            socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:127.0.0.1:$LOCAL_PORT &
        fi
        
        echo $! > "$LOCK_FILE"
    ) 200>"$LOCK_FILE"
}

stop_tunnel() {
    [ -f "$LOCK_FILE" ] && kill -9 $(cat "$LOCK_FILE") 2>/dev/null
    rm -f "$LOCK_FILE"
    pkill -f "socat.*$LOCAL_PORT"
}

check_status() {
    SERVER_TYPE=$(detect_server_type)
    
    echo -e "\n${YELLOW}=== Service Status ==="
    systemctl status "${SERVICE_NAME}-${SERVER_TYPE}" --no-pager
    
    echo -e "\n=== Active Connections ==="
    ss -ulnp | grep -E "$LOCAL_PORT|socat"
    
    echo -e "\n=== Connection Count ==="
    netstat -anup | grep "$LOCAL_PORT"
}

### Helper Functions ###

detect_server_type() {
    if [[ -f "$CONFIG_DIR/iran.conf" ]]; then
        echo "iran"
    elif [[ -f "$CONFIG_DIR/foreign.conf" ]]; then
        echo "foreign"
    else
        echo ""
    fi
}

show_menu() {
    clear
    echo -e "${YELLOW}=== UDP Tunnel Manager ==="
    echo -e "1. Setup Iran Server"
    echo -e "2. Setup Foreign Server"
    echo -e "3. Start Tunnel"
    echo -e "4. Stop Tunnel"
    echo -e "5. Check Status"
    echo -e "6. Restart Service"
    echo -e "7. Uninstall"
    echo -e "8. Exit${NC}"
    echo -n "Select option: "
}

### Main Execution ###

case "$1" in
    "start")
        start_tunnel "$2"
        ;;
    "stop")
        stop_tunnel
        ;;
    *)
        while true; do
            show_menu
            read choice
            
            case $choice in
                1) setup_iran ;;
                2) setup_foreign ;;
                3) 
                    SERVER_TYPE=$(detect_server_type)
                    systemctl start "${SERVICE_NAME}-${SERVER_TYPE}"
                    ;;
                4)
                    SERVER_TYPE=$(detect_server_type)
                    systemctl stop "${SERVICE_NAME}-${SERVER_TYPE}"
                    ;;
                5) check_status ;;
                6)
                    SERVER_TYPE=$(detect_server_type)
                    systemctl restart "${SERVICE_NAME}-${SERVER_TYPE}"
                    ;;
                7) uninstall ;;
                8) exit 0 ;;
                *) echo -e "${RED}Invalid option!${NC}" ;;
            esac
            
            read -p "Press Enter to continue..."
        done
        ;;
esac
