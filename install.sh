#!/bin/bash
# install.sh – Ultimate Tunnel Manager (UTM)
# اجرا فقط با دستور: bash install.sh
# بر روی سرور ایران یا خارجی بدون سوال اضافه

set -euo pipefail

# پیام خوش‌آمدگویی
clear
echo -e "\n🚀 UTM Installer - Ultimate Tunnel Manager"
echo "==========================================="

echo "Select an option:"
echo "1) Install / Configure Tunnels"
echo "2) Uninstall UTM Completely"
echo "3) Exit"
read -p "Choice [1-3]: " choice

if [[ "$choice" == "2" ]]; then
  bash <(curl -fsSL https://raw.githubusercontent.com/taherimohsen/utm/main/uninstall.sh)
  exit 0
elif [[ "$choice" == "3" ]]; then
  echo "Bye!"
  exit 0
fi

# مسیرها
BASE="/opt/utm"
SCRIPTS="$BASE/scripts"
LOGS="$BASE/logs"
TEMPLATE="$BASE/templates"
mkdir -p "$SCRIPTS" "$LOGS" "$TEMPLATE"

# نصب پیش‌نیازها
apt update
apt install -y haproxy ufw socat iptables-persistent dnsutils curl netcat-openbsd rsyslog

# نصب udp2raw در صورت لزوم
if ! command -v udp2raw &>/dev/null; then
  echo "🔽 Installing udp2raw..."
  curl -sL -o /usr/local/bin/udp2raw \
    https://github.com/wangyu-/udp2raw-tunnel/releases/latest/download/udp2raw_amd64
  chmod +x /usr/local/bin/udp2raw
fi

# فعال‌سازی لاگ HAProxy
cat > /etc/rsyslog.d/49-haproxy.conf <<EOF
if ($programname == 'haproxy') then /var/log/haproxy.log
& stop
EOF
systemctl restart rsyslog

# فعال‌سازی IP forwarding
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# گرفتن ورودی‌ها از کاربر
read -p "Is this server in Iran? (y/n): " is_iran
PROT=(SSH Vless Vmess OpenVPN)
PORT=(); PT=(); BE=(); RP=(); M=()

for p in "${PROT[@]}"; do
  read -p "Enable $p? (y/n): " en
  if [[ $en != y ]]; then
    PORT+=(""); PT+=(""); BE+=(""); RP+=(""); M+=("")
    continue
  fi
  read -p "  Local port for $p: " lp
  read -p "  Protocol type (tcp/udp): " t
  read -p "  Foreign server IP/domain: " bi
  read -p "  Remote port at foreign side: " rp

  if [[ $t == udp ]]; then
    echo "  Choose UDP method: 1)iptables 2)socat 3)udp2raw"
    read -p "  choice [1-3]: " c
    case $c in 2) md="socat";;3) md="udp2raw";;*) md="iptables";;esac
  else
    md="haproxy"
  fi

  PORT+=("$lp"); PT+=("$t"); BE+=("$bi"); RP+=("$rp"); M+=("$md")
done

# ساخت تنظیمات HAProxy برای TCP
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

# پیکربندی تونل‌ها
for i in "${!PROT[@]}"; do
  p="${PROT[i]}"; lp="${PORT[i]}"; t="${PT[i]}"; bi="${BE[i]}"; rp="${RP[i]}"; md="${M[i]}"
  [[ -z "$lp" ]] && continue

  if [[ $t == tcp ]]; then
    echo "👉 Configuring TCP $p via HAProxy on port $lp..."
    cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${p}_front
  bind *:${lp}
  default_backend ${p}_back

backend ${p}_back
  server ${p}_srv ${bi}:${rp} check
EOF
    ufw allow "$lp"/tcp

  else
    echo "👉 Configuring UDP $p via $md on port $lp..."
    ufw allow "$lp"/udp
    case $md in
      iptables)
        iptables -t nat -A PREROUTING -p udp --dport "$lp" -j DNAT --to-destination "${bi}:${rp}"
        iptables -t nat -A POSTROUTING -j MASQUERADE
        ;;
      socat)
        nohup socat UDP4-RECVFROM:"$lp",fork UDP4-SENDTO:"${bi}:${rp}" \
          &> "$LOGS/${p}_socat.log" &
        ;;
      udp2raw)
        nohup udp2raw -c -r"${bi}:${rp}" -l0.0.0.0:"$lp" -k utm-secret --raw-mode faketcp \
          &> "$LOGS/${p}_udp2raw.log" &
        ;;
    esac
  fi
done

# ری‌استارت و فعال‌سازی HAProxy
if grep -q frontend /etc/haproxy/haproxy.cfg; then
  systemctl enable haproxy
  systemctl restart haproxy
fi

# ذخیره iptables و تنظیم UFW
netfilter-persistent save
ufw --force enable

# نمایش نتیجه نهایی
echo -e "\n✅ Tunnel setup complete. Summary:"
for i in "${!PROT[@]}"; do
  [[ -n "${PORT[i]}" ]] && \
    echo " • ${PROT[i]} (${PT[i]}): ${PORT[i]} → ${BE[i]}:${RP[i]} (${M[i]})"
done
echo -e "\n📌 IP forwarding: enabled"
echo "📂 HAProxy config: /etc/haproxy/haproxy.cfg"
echo "📄 Logs at: $LOGS"
echo -e "\n🚀 All done."
