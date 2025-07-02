#!/bin/bash
# File: install.sh - UTM (Ultimate Tunnel Manager)
# Purpose: نصب و راه‌اندازی کامل تونل TCP/UDP بین سرور ایران و خارج با پورت دلخواه

set -euo pipefail

clear
echo "\n🚀 UTM Installer - Ultimate Tunnel Manager"
echo "=========================================="

# مسیرها
BASE_DIR="/opt/utm"
SCRIPT_DIR="$BASE_DIR/scripts"
LOG_DIR="$BASE_DIR/logs"
TEMPLATE_DIR="$BASE_DIR/templates"

mkdir -p "$SCRIPT_DIR" "$LOG_DIR" "$TEMPLATE_DIR"

# نصب ابزارهای مورد نیاز
apt update && apt install -y haproxy ufw socat iptables-persistent dnsutils curl netcat-openbsd rsyslog

# نصب udp2raw اگر نصب نشده باشد
if ! command -v udp2raw &>/dev/null; then
  echo "🔽 Installing udp2raw..."
  curl -L -o /usr/local/bin/udp2raw https://github.com/wangyu-/udp2raw-tunnel/releases/latest/download/udp2raw_amd64
  chmod +x /usr/local/bin/udp2raw
fi

# فعال‌سازی لاگ haproxy
cat > /etc/rsyslog.d/49-haproxy.conf <<EOF
if ($programname == 'haproxy') then /var/log/haproxy.log
& stop
EOF
systemctl restart rsyslog

# فعال‌سازی IP forwarding
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  sysctl -p
fi

# کد اصلی تنظیم تونل
read -p "Is this server located in Iran? (y/n): " is_iran

PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
PORTS=()
PROTOCOL_TYPES=()
BACKENDS=()
REMOTE_PORTS=()
METHODS=()

for proto in "${PROTOCOLS[@]}"; do
  read -p "Enable $proto? (y/n): " enable
  if [[ "$enable" != "y" ]]; then
    PORTS+=("")
    PROTOCOL_TYPES+=("")
    BACKENDS+=("")
    REMOTE_PORTS+=("")
    METHODS+=("")
    continue
  fi

  read -p "Local port for $proto: " port
  read -p "Protocol type (tcp/udp) for $proto: " ptype
  read -p "Foreign server IP/domain: " backend
  read -p "Remote port on foreign server: " remote_port

  if [[ "$ptype" == "udp" ]]; then
    echo "Select UDP tunneling method for $proto:"
    echo "1) iptables (default)"
    echo "2) socat"
    echo "3) udp2raw"
    read -p "Choice [1-3]: " choice
    case $choice in
      2) method="socat";;
      3) method="udp2raw";;
      *) method="iptables";;
    esac
  else
    method="haproxy"
  fi

  PORTS+=("$port")
  PROTOCOL_TYPES+=("$ptype")
  BACKENDS+=("$backend")
  REMOTE_PORTS+=("$remote_port")
  METHODS+=("$method")

done

# ساخت فایل کانفیگ haproxy
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0 info
    daemon

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h
EOF

# تنظیم هر پروتکل
for i in "${!PROTOCOLS[@]}"; do
  proto="${PROTOCOLS[$i]}"
  port="${PORTS[$i]}"
  ptype="${PROTOCOL_TYPES[$i]}"
  backend="${BACKENDS[$i]}"
  remote_port="${REMOTE_PORTS[$i]}"
  method="${METHODS[$i]}"

  if [[ -z "$port" ]]; then
    continue
  fi

  if [[ "$ptype" == "tcp" ]]; then
    echo "🔧 Setting up TCP tunnel for $proto via HAProxy..."
    cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${proto}_front
    bind *:${port}
    mode tcp
    default_backend ${proto}_back

backend ${proto}_back
    mode tcp
    server ${proto}_server ${backend}:${remote_port} check
EOF
    ufw allow ${port}/tcp

  else
    echo "⚡ Setting up UDP tunnel for $proto via $method..."
    case $method in
      iptables)
        iptables -t nat -A PREROUTING -p udp --dport $port -j DNAT --to-destination $backend:$remote_port
        iptables -t nat -A POSTROUTING -j MASQUERADE
        ;;

      socat)
        nohup socat UDP4-RECVFROM:$port,fork UDP4-SENDTO:$backend:$remote_port &> "$LOG_DIR/${proto}_socat.log" &
        ;;

      udp2raw)
        nohup udp2raw -c -r$backend:$remote_port -l0.0.0.0:$port -k utm-secret --raw-mode faketcp &> "$LOG_DIR/${proto}_udp2raw.log" &
        ;;
    esac
    ufw allow ${port}/udp
  fi

done

# ریستارت سرویس‌ها
if grep -q frontend /etc/haproxy/haproxy.cfg; then
  systemctl enable haproxy
  systemctl restart haproxy
fi

netfilter-persistent save
ufw --force enable

# نمایش خلاصه

echo -e "\n✅ All tunnels have been configured."
echo "📋 Summary:"
for i in "${!PROTOCOLS[@]}"; do
  if [[ -n "${PORTS[$i]}" ]]; then
    echo "  ${PROTOCOLS[$i]} (${PROTOCOL_TYPES[$i]}): ${PORTS[$i]} → ${BACKENDS[$i]}:${REMOTE_PORTS[$i]} via ${METHODS[$i]}"
  fi
done

echo -e "\n📡 IP forwarding enabled"
echo "🔐 Firewall adjusted"
echo "🟢 HAProxy config: /etc/haproxy/haproxy.cfg"
echo "🗂️ Logs: $LOG_DIR"
echo -e "\n🚀 Done."
exit 0
