#!/bin/bash
# GitHub: https://github.com/yourusername/udp-multitunnel
# Version: 2.0
# License: MIT

# تنظیمات پیش‌فرض
CONFIG_DIR="/etc/udp-tunnels"
LOG_DIR="/var/log/udp-tunnels"
TUNNEL_PORT=42347
SERVICE_NAME="udp-tunnel"

# رنگ‌های برای نمایش زیباتر
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
    echo -e "${YELLOW}=== مدیریت تانل‌های UDP ==="
    echo -e "1. تنظیم سرور ایران"
    echo -e "2. تنظیم سرور خارج"
    echo -e "3. نمایش وضعیت تانل‌ها"
    echo -e "4. راه‌اندازی سرویس"
    echo -e "5. متوقف کردن سرویس"
    echo -e "6. حذف تانل"
    echo -e "7. خروج${NC}"
    echo -n "انتخاب شما: "
}

# تابع تنظیم سرور ایران
setup_iran_server() {
    echo -e "\n${BLUE}=== تنظیم سرور ایران ===${NC}"
    
    # دریافت شناسه سرور
    read -p "شناسه سرور ایران (مثلا 1): " SERVER_ID
    
    # بررسی تکراری نبودن شناسه
    if [[ -f "$CONFIG_DIR/iran_$SERVER_ID.conf" ]]; then
        echo -e "${RED}سرور با این شناسه قبلا تنظیم شده است!${NC}"
        return 1
    fi
    
    # دریافت تنظیمات
    read -p "پورت محلی (پیشفرض $TUNNEL_PORT): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}
    
    read -p "لیست سرورهای خارجی (با کاما جدا کنید): " FOREIGN_SERVERS
    
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
    
    echo -e "${GREEN}تنظیمات سرور ایران با شناسه $SERVER_ID ذخیره شد.${NC}"
}

# تابع تنظیم سرور خارج
setup_foreign_server() {
    echo -e "\n${BLUE}=== تنظیم سرور خارج ===${NC}"
    
    # دریافت شناسه سرور
    read -p "شناسه سرور خارج (مثلا 1): " SERVER_ID
    
    # بررسی تکراری نبودن شناسه
    if [[ -f "$CONFIG_DIR/foreign_$SERVER_ID.conf" ]]; then
        echo -e "${RED}سرور با این شناسه قبلا تنظیم شده است!${NC}"
        return 1
    fi
    
    # دریافت تنظیمات
    read -p "پورت محلی (پیشفرض $TUNNEL_PORT): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}
    
    read -p "لیست سرورهای ایرانی (با کاما جدا کنید): " IRAN_SERVERS
    
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
    
    echo -e "${GREEN}تنظیمات سرور خارج با شناسه $SERVER_ID ذخیره شد.${NC}"
}

# تابع نمایش وضعیت
show_status() {
    echo -e "\n${BLUE}=== وضعیت تانل‌ها ===${NC}"
    
    # نمایش سرورهای ایران
    echo -e "${YELLOW}سرورهای ایران:${NC}"
    for conf in "$CONFIG_DIR"/iran_*.conf; do
        if [[ -f "$conf" ]]; then
            source "$conf"
            echo -e "شناسه: $SERVER_ID | پورت: $LOCAL_PORT"
            echo "سرورهای خارجی: ${FOREIGN_SERVERS[*]}"
            echo "-----------------------------------"
        fi
    done
    
    # نمایش سرورهای خارج
    echo -e "${YELLOW}سرورهای خارج:${NC}"
    for conf in "$CONFIG_DIR"/foreign_*.conf; do
        if [[ -f "$conf" ]]; then
            source "$conf"
            echo -e "شناسه: $SERVER_ID | پورت: $LOCAL_PORT"
            echo "سرورهای ایرانی: ${IRAN_SERVERS[*]}"
            echo "-----------------------------------"
        fi
    done
    
    # نمایش سرویس‌های فعال
    echo -e "${YELLOW}سرویس‌های فعال:${NC}"
    systemctl list-units --type=service | grep "$SERVICE_NAME"
}

# تابع راه‌اندازی سرویس
start_service() {
    echo -e "\n${BLUE}=== راه‌اندازی سرویس ===${NC}"
    
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
            echo -e "${GREEN}سرویس برای $conf_name راه‌اندازی شد.${NC}"
        fi
    done
}

# تابع توقف سرویس
stop_service() {
    echo -e "\n${BLUE}=== توقف سرویس ===${NC}"
    
    for conf in "$CONFIG_DIR"/*.conf; do
        if [[ -f "$conf" ]]; then
            conf_name=$(basename "$conf" .conf)
            systemctl stop "$SERVICE_NAME@$conf_name"
            systemctl disable "$SERVICE_NAME@$conf_name"
            echo -e "${RED}سرویس برای $conf_name متوقف شد.${NC}"
        fi
    done
}

# تابع حذف تانل
remove_tunnel() {
    echo -e "\n${BLUE}=== حذف تانل ===${NC}"
    
    read -p "شناسه تانل (مثلا iran_1 یا foreign_1): " TUNNEL_ID
    
    if [[ ! -f "$CONFIG_DIR/$TUNNEL_ID.conf" ]]; then
        echo -e "${RED}تانل با این شناسه یافت نشد!${NC}"
        return 1
    fi
    
    # توقف سرویس
    systemctl stop "$SERVICE_NAME@$TUNNEL_ID" 2>/dev/null
    systemctl disable "$SERVICE_NAME@$TUNNEL_ID" 2>/dev/null
    
    # حذف فایل‌ها
    rm -f "$CONFIG_DIR/$TUNNEL_ID.conf"
    rm -f "/usr/local/bin/udp-tunnel-${TUNNEL_ID#*_}.sh"
    rm -f "$LOG_DIR/tunnel-$TUNNEL_ID.log"
    
    echo -e "${GREEN}تانل $TUNNEL_ID با موفقیت حذف شد.${NC}"
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
        *) echo -e "${RED}گزینه نامعتبر!${NC}" ;;
    esac
    
    read -p "برای ادامه Enter بزنید..."
done
