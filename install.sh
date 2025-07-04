#!/bin/bash
# Ultimate UDP Tunnel Manager - Simplified Version
# GitHub: https://github.com/yourusername/udp-tunnel-simple

CONFIG_DIR="/etc/udp-tunnel"
LOG_FILE="/var/log/udp-tunnel.log"
SERVICE_NAME="udp-tunnel"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

init_system() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
}

setup_tunnel() {
    echo -e "\n${YELLOW}=== Tunnel Setup ===${NC}"
    
    read -p "Is this Iran server? (y/n): " IS_IRAN
    
    if [[ "$IS_IRAN" =~ ^[Yy] ]]; then
        # Iran Server
        read -p "Local UDP port (default 42347): " LOCAL_PORT
        LOCAL_PORT=${LOCAL_PORT:-42347}
        
        read -p "Foreign server IP: " FOREIGN_IP
        read -p "Foreign server port (default $LOCAL_PORT): " TARGET_PORT
        TARGET_PORT=${TARGET_PORT:-$LOCAL_PORT}
        
        echo "LOCAL_PORT=$LOCAL_PORT" > "$CONFIG_DIR/config"
        echo "FOREIGN_IP=$FOREIGN_IP" >> "$CONFIG_DIR/config"
        echo "TARGET_PORT=$TARGET_PORT" >> "$CONFIG_DIR/config"
        
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOL
[Unit]
Description=UDP Tunnel Service
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONFIG_DIR/config
ExecStart=socat -u UDP4-LISTEN:\$LOCAL_PORT,reuseaddr,fork UDP4:\$FOREIGN_IP:\$TARGET_PORT
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOL

    else
        # Foreign Server
        apt install -y socat iptables-persistent
        
        read -p "Listen port (default 42347): " LISTEN_PORT
        LISTEN_PORT=${LISTEN_PORT:-42347}
        read -p "OpenVPN port: " TARGET_PORT
        
        iptables -t nat -A PREROUTING -p udp --dport $LISTEN_PORT -j REDIRECT --to-port $TARGET_PORT
        iptables -A INPUT -p udp --dport $LISTEN_PORT -j ACCEPT
        netfilter-persistent save
        
        echo "LISTEN_PORT=$LISTEN_PORT" > "$CONFIG_DIR/config"
        echo "TARGET_PORT=$TARGET_PORT" >> "$CONFIG_DIR/config"
        
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOL
[Unit]
Description=UDP Tunnel Service
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONFIG_DIR/config
ExecStart=socat -u UDP4-LISTEN:\$LISTEN_PORT,reuseaddr,fork UDP4:127.0.0.1:\$TARGET_PORT
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOL
    fi

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    
    echo -e "${GREEN}Done! Service is running.${NC}"
}

manage_service() {
    echo -e "\n${YELLOW}Service Management${NC}"
    echo "1. Start tunnel"
    echo "2. Stop tunnel"
    echo "3. Restart tunnel"
    echo "4. Check status"
    read -p "Your choice: " choice
    
    case $choice in
        1) systemctl start "$SERVICE_NAME" ;;
        2) systemctl stop "$SERVICE_NAME" ;;
        3) systemctl restart "$SERVICE_NAME" ;;
        4) systemctl status "$SERVICE_NAME" ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
}

# Main Menu
while true; do
    clear
    echo -e "${YELLOW}=== UDP Tunnel Manager ==="
    echo "1. Setup tunnel"
    echo "2. Manage service"
    echo "3. Exit"
    read -p "Your choice: " choice
    
    case $choice in
        1) setup_tunnel ;;
        2) manage_service ;;
        3) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
    
    read -p "Press Enter to continue..."
done