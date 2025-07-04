#!/bin/bash
# Advanced UDP Tunnel Manager - Multi-Server Support
# GitHub: https://github.com/yourusername/advanced-udp-tunnel

CONFIG_DIR="/etc/udp-tunnel"
LOG_FILE="/var/log/udp-tunnel.log"
SERVICE_NAME="udp-tunnel"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

init_system() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

clean_installation() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
}

setup_tunnel() {
    clean_installation
    init_system
    
    echo -e "\n${BLUE}=== Advanced Tunnel Setup ===${NC}"
    
    read -p "Is this the Iran server? (y/n): " IS_IRAN
    
    if [[ "$IS_IRAN" =~ ^[Yy] ]]; then
        # Iran server setup
        read -p "Enter local UDP port (default 42347): " LOCAL_PORT
        LOCAL_PORT=${LOCAL_PORT:-42347}
        
        echo "Enter foreign server IPs (one per line, end with empty line):"
        FOREIGN_SERVERS=()
        while true; do
            read -p "> " SERVER_IP
            [ -z "$SERVER_IP" ] && break
            FOREIGN_SERVERS+=("$SERVER_IP")
        done
        
        read -p "Enter target port on foreign servers (default $LOCAL_PORT): " TARGET_PORT
        TARGET_PORT=${TARGET_PORT:-$LOCAL_PORT}
        
        echo "LOCAL_PORT=$LOCAL_PORT" > "$CONFIG_DIR/config"
        echo "TARGET_PORT=$TARGET_PORT" >> "$CONFIG_DIR/config"
        printf "FOREIGN_SERVERS=(%s)\n" "${FOREIGN_SERVERS[*]}" >> "$CONFIG_DIR/config"
        echo "SERVER_TYPE=iran" >> "$CONFIG_DIR/config"
        
        # Create load balancing service
        create_load_balanced_service
    else
        # Foreign server setup
        apt-get install -y iptables-persistent socat
        
        read -p "Enter local UDP port to listen (default 42347): " LISTEN_PORT
        LISTEN_PORT=${LISTEN_PORT:-42347}
        
        read -p "Enter target port for OpenVPN: " TARGET_PORT
        while [ "$LISTEN_PORT" -eq "$TARGET_PORT" ]; do
            echo -e "${RED}Error: Listen and target ports must differ!${NC}"
            read -p "Enter target port for OpenVPN: " TARGET_PORT
        done
        
        # Configure iptables
        iptables -t nat -A PREROUTING -p udp --dport $LISTEN_PORT -j REDIRECT --to-port $TARGET_PORT
        iptables -A INPUT -p udp --dport $LISTEN_PORT -j ACCEPT
        netfilter-persistent save
        
        echo "LISTEN_PORT=$LISTEN_PORT" > "$CONFIG_DIR/config"
        echo "TARGET_PORT=$TARGET_PORT" >> "$CONFIG_DIR/config"
        echo "SERVER_TYPE=foreign" >> "$CONFIG_DIR/config"
        
        create_foreign_service
    fi

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    echo -e "${GREEN}Setup completed!${NC}"
    echo -e "Start service with: systemctl start $SERVICE_NAME"
}

create_load_balanced_service() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOL
[Unit]
Description=Advanced UDP Tunnel (Load Balanced)
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONFIG_DIR/config
ExecStart=/usr/bin/bash -c '
    servers=(\${FOREIGN_SERVERS[@]})
    while true; do
        for server in "\${servers[@]}"; do
            socat -u UDP4-LISTEN:\$LOCAL_PORT,reuseaddr,fork UDP4:\$server:\$TARGET_PORT &
        done
        wait
        sleep 1
    done
'
Restart=always
RestartSec=3s
User=root
Group=root
StandardOutput=file:$LOG_FILE
StandardError=file:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOL
}

create_foreign_service() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOL
[Unit]
Description=UDP Tunnel Foreign Server
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONFIG_DIR/config
ExecStart=/usr/bin/socat -u UDP4-LISTEN:\$LISTEN_PORT,reuseaddr,fork UDP4:127.0.0.1:\$TARGET_PORT
Restart=always
RestartSec=3s
User=root
Group=root
StandardOutput=file:$LOG_FILE
StandardError=file:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOL
}

# ... (بقیه توابع مانند main_menu و service_control مانند قبل)

# Ensure root
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Run as root!${NC}"; exit 1; }

# Main Execution
while true; do
    main_menu
    read choice
    # ... (منوی اصلی مانند قبل)
done