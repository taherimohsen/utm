#!/bin/bash
# سیستم تانل‌زنی پیشرفته UDP
# GitHub: https://github.com/yourusername/udp-multitunnel
# Version: 2.0
# License: MIT

# تنظیمات پیش‌فرض
CONFIG_DIR="/etc/udp-tunnels"
LOG_DIR="/var/log/udp-tunnels"
TUNNEL_PORT=42347
SERVICE_NAME="udp-tunnel"

# رنگ‌های برای نمایش بهتر
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ایجاد ساختار دایرکتوری‌ها
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

# تابع نمایش منوی اصلی
show_main_menu() {
    clear
    echo -e "${YELLOW}=== UDP Tunnel Management ==="
    echo -e "1. Configure Iran Server"
    echo -e "2. Configure Foreign Server"
    echo -e "3. Show Tunnel Status"
    echo -e "4. Start Tunnel Service"
    echo -e "5. Stop Tunnel Service"
    echo -e "6. Remove Tunnel"
    echo -e "7. Exit${NC}"
    echo -n "Your choice: "
}

# تابع تنظیم سرور ایران
setup_iran_server() {
    echo -e "\n${BLUE}=== Iran Server Setup ===${NC}"
    
    # دریافت شناسه سرور
    read -p "Enter Iran Server ID (e.g. 1): " SERVER_ID
    
    # بررسی تکراری نبودن شناسه
    if [[ -f "$CONFIG_DIR/iran_$SERVER_ID.conf" ]]; then
        echo -e "${RED}Server with this ID already exists!${NC}"
        return 1
    fi
    
    # دریافت تنظیمات
    read -p "Local port (default $TUNNEL_PORT): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}
    
    read -p "Foreign server addresses (comma separated): " FOREIGN_SERVERS
    
    # ذخیره تنظیمات
    cat > "$CONFIG_DIR/iran_$SERVER_ID.conf" <<EOL
LOCAL_PORT=$LOCAL_PORT
FOREIGN_SERVERS=(${FOREIGN_SERVERS//,/ })
SERVER_TYPE=iran
SERVER_ID=$SERVER_ID
EOL

    # ایجاد اسکریپت تانل
    cat > "/usr/local/bin/udp-tunnel-$SERVER_ID.sh" <<'EOL'
#!/bin/bash
CONFIG_FILE="$1"
LOG_FILE="$2"

# بارگیری تنظیمات
source "$CONFIG_FILE"

# تابع ایجاد تانل
create_tunnel() {
    local foreign_server=$1
    while true; do
        echo "$(date): Connecting to $foreign_server" >> "$LOG_FILE"
        socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$foreign_server:$LOCAL_PORT
        sleep 5
    done
}

# اجرای تانل‌ها برای همه سرورهای خارجی
for foreign in "${FOREIGN_SERVERS[@]}"; do
    create_tunnel "$foreign" &
done

wait
EOL

    chmod +x "/usr/local/bin/udp-tunnel-$SERVER_ID.sh"
    
    echo -e "${GREEN}Iran server $SERVER_ID configured successfully.${NC}"
}

# تابع تنظیم سرور خارج
setup_foreign_server() {
    echo -e "\n${BLUE}=== Foreign Server Setup ===${NC}"
    
    # دریافت شناسه سرور
    read -p "Enter Foreign Server ID (e.g. 1): " SERVER_ID
    
    # بررسی تکراری نبودن شناسه
    if [[ -f "$CONFIG_DIR/foreign_$SERVER_ID.conf" ]]; then
        echo -e "${RED}Server with this ID already exists!${NC}"
        return 1
    fi
    
    # دریافت تنظیمات
    read -p "Local port (default $TUNNEL_PORT): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}
    
    read -p "Iran server addresses (comma separated): " IRAN_SERVERS
    
    # ذخیره تنظیمات
    cat > "$CONFIG_DIR/foreign_$SERVER_ID.conf" <<EOL
LOCAL_PORT=$LOCAL_PORT
IRAN_SERVERS=(${IRAN_SERVERS//,/ })
SERVER_TYPE=foreign
SERVER_ID=$SERVER_ID
EOL

    # ایجاد اسکریپت تانل
    cat > "/usr/local/bin/udp-tunnel-$SERVER_ID.sh" <<'EOL'
#!/bin/bash
CONFIG_FILE="$1"
LOG_FILE="$2"

# بارگیری تنظیمات
source "$CONFIG_FILE"

# تابع ایجاد تانل
create_tunnel() {
    local iran_server=$1
    while true; do
        echo "$(date): Connecting to $iran_server" >> "$LOG_FILE"
        socat -u UDP4-LISTEN:$LOCAL_PORT,reuseaddr,fork UDP4:$iran_server:$LOCAL_PORT
        sleep 5
    done
}

# اجرای تانل‌ها برای همه سرورهای ایرانی
for iran in "${IRAN_SERVERS[@]}"; do
    create_tunnel "$iran" &
done

wait
EOL

    chmod +x "/usr/local/bin/udp-tunnel-$SERVER_ID.sh"
    
    echo -e "${GREEN}Foreign server $SERVER_ID configured successfully.${NC}"
}

# تابع نمایش وضعیت
show_status() {
    echo -e "\n${BLUE}=== Tunnel Status ===${NC}"
    
    # نمایش سرورهای ایران
    echo -e "${YELLOW}Iran Servers:${NC}"
    for conf in "$CONFIG_DIR"/iran_*.conf; do
        if [[ -f "$conf" ]]; then
            source "$conf"
            echo -e "ID: $SERVER_ID | Port: $LOCAL_PORT"
            echo "Foreign Servers: ${FOREIGN_SERVERS[*]}"
            echo "-----------------------------------"
        fi
    done
    
    # نمایش سرورهای خارج
    echo -e "${YELLOW}Foreign Servers:${NC}"
    for conf in "$CONFIG_DIR"/foreign_*.conf; do
        if [[ -f "$conf" ]]; then
            source "$conf"
            echo -e "ID: $SERVER_ID | Port: $LOCAL_PORT"
            echo "Iran Servers: ${IRAN_SERVERS[*]}"
            echo "-----------------------------------"
        fi
    done
    
    # نمایش سرویس‌های فعال
    echo -e "${YELLOW}Active Services:${NC}"
    systemctl list-units --type=service | grep "$SERVICE_NAME"
}

# تابع راه‌اندازی سرویس
start_service() {
    echo -e "\n${BLUE}=== Starting Tunnel Service ===${NC}"
    
    # ایجاد فایل سرویس systemd
    cat > "/etc/systemd/system/$SERVICE_NAME@.service" <<EOL
[Unit]
Description=UDP Tunnel Service %I
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-tunnel-%i.sh $CONFIG_DIR/%i.conf $LOG_DIR/tunnel-%i.log
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    
    # راه‌اندازی سرویس برای همه پیکربندی‌ها
    for conf in "$CONFIG_DIR"/*.conf; do
        if [[ -f "$conf" ]]; then
            conf_name=$(basename "$conf" .conf)
            systemctl enable "$SERVICE_NAME@$conf_name"
            systemctl start "$SERVICE_NAME@$conf_name"
            echo -e "${GREEN}Service started for $conf_name.${NC}"
        fi
    done
}

# تابع توقف سرویس
stop_service() {
    echo -e "\n${BLUE}=== Stopping Tunnel Service ===${NC}"
    
    for conf in "$CONFIG_DIR"/*.conf; do
        if [[ -f "$conf" ]]; then
            conf_name=$(basename "$conf" .conf)
            systemctl stop "$SERVICE_NAME@$conf_name"
            systemctl disable "$SERVICE_NAME@$conf_name"
            echo -e "${RED}Service stopped for $conf_name.${NC}"
        fi
    done
}

# تابع حذف تانل
remove_tunnel() {
    echo -e "\n${BLUE}=== Remove Tunnel ===${NC}"
    
    read -p "Enter tunnel ID (e.g. iran_1 or foreign_1): " TUNNEL_ID
    
    if [[ ! -f "$CONFIG_DIR/$TUNNEL_ID.conf" ]]; then
        echo -e "${RED}Tunnel not found!${NC}"
        return 1
    fi
    
    # توقف سرویس
    systemctl stop "$SERVICE_NAME@$TUNNEL_ID" 2>/dev/null
    systemctl disable "$SERVICE_NAME@$TUNNEL_ID" 2>/dev/null
    
    # حذف فایل‌ها
    rm -f "$CONFIG_DIR/$TUNNEL_ID.conf"
    rm -f "/usr/local/bin/udp-tunnel-${TUNNEL_ID#*_}.sh"
    rm -f "$LOG_DIR/tunnel-$TUNNEL_ID.log"
    
    echo -e "${GREEN}Tunnel $TUNNEL_ID removed successfully.${NC}"
}

# حلقه اصلی برنامه
while true; do
    show_main_menu
    read choice
    
    case $choice in
        1) setup_iran_server ;;
        2) setup_foreign_server ;;
        3) show_status ;;
        4) start_service ;;
        5) stop_service ;;
        6) remove_tunnel ;;
        7) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
    
    read -p "Press Enter to continue..."
done
