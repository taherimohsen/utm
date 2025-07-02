#!/bin/bash
# install.sh – Ultimate Tunnel Manager - کامل و خودکار برای ایران و خارج
set -euo pipefail

clear
echo "🚀 Ultimate HAProxy Tunnel Manager - Complete Auto Setup"
echo "========================================================="

# بررسی نصب پیش‌نیازها و نصب در صورت نبود
install_prereqs() {
  echo "🔍 Installing prerequisites..."
  apt update
  apt install -y haproxy ufw netcat-openbsd dnsutils iptables-persistent socat curl sudo
}

check_haproxy_version() {
  if ! haproxy -v | grep -qE "2\.4|2\.[5-9]"; then
    echo "⬆️ Upgrading HAProxy to 2.4+ for UDP support..."
    add-apt-repository -y ppa:vbernat/haproxy-2.4
    apt update
    apt install -y haproxy=2.4.*
  fi
}

enable_ip_forwarding() {
  echo "🛠 Enabling IP forwarding..."
  sysctl -w net.ipv4.ip_forward=1
  sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p
}

# پرسش و دریافت تنظیمات پروتکل‌ها
declare -A PORTS_LOCAL PORTS_REMOTE PROTO_TYPES UDP_METHODS

PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
DEFAULT_LOCAL_PORTS=("4234" "41369" "41374" "42347")
DEFAULT_REMOTE_PORTS=("4234" "41369" "41374" "42347")

echo "📋 Protocol setup:"

for proto in "${PROTOCOLS[@]}"; do
  read -p "Enable $proto? (y/n): " enable
  if [[ "$enable" =~ ^[Yy]$ ]]; then
    while true; do
      read -p "Local port for $proto (default: ${DEFAULT_LOCAL_PORTS[$((i))]}): " lp
      lp=${lp:-${DEFAULT_LOCAL_PORTS[$((i))]}}
      if [[ "$lp" =~ ^[0-9]+$ ]] && [ "$lp" -ge 1024 ] && [ "$lp" -le 65535 ]; then
        PORTS_LOCAL[$proto]=$lp
        break
      else
        echo "❌ Invalid port!"
      fi
    done
    while true; do
      read -p "Remote server IP/domain for $proto: " remoteip
      if [[ -n "$remoteip" ]]; then
        PORTS_REMOTE[$proto]="$remoteip"
        break
      else
        echo "❌ Please enter a valid IP or domain!"
      fi
    done
    while true; do
      read -p "Remote port for $proto (default: ${DEFAULT_REMOTE_PORTS[$((i))]}): " rp
      rp=${rp:-${DEFAULT_REMOTE_PORTS[$((i))]}}
      if [[ "$rp" =~ ^[0-9]+$ ]] && [ "$rp" -ge 1024 ] && [ "$rp" -le 65535 ]; then
        PROTO_TYPES[$proto]=$rp
        break
      else
        echo "❌ Invalid port!"
      fi
    done

    if [[ "$proto" == "OpenVPN" ]]; then
      read -p "Select OpenVPN protocol TCP (1) or UDP (2) (default 1): " ovpn_proto
      ovpn_proto=${ovpn_proto:-1}
      if [ "$ovpn_proto" == "2" ]; then
        UDP_METHODS[$proto]="udp2raw"
      else
        UDP_METHODS[$proto]="haproxy"
      fi
    else
      UDP_METHODS[$proto]="haproxy"
    fi
  fi
  ((i++))
done

# تولید کانفیگ HAProxy و iptables/socat/udp2raw بر اساس تنظیمات
generate_config() {
  echo "🛠 Generating configuration..."

  # کانفیگ HAProxy
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0 info
    maxconn 10000
    daemon
    tune.ssl.default-dh-param 2048
    stats socket /run/haproxy/admin.sock mode 660 level admin

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h
EOF

  for proto in "${!PORTS_LOCAL[@]}"; do
    local_port=${PORTS_LOCAL[$proto]}
    remote_ip=${PORTS_REMOTE[$proto]}
    remote_port=${PROTO_TYPES[$proto]}
    method=${UDP_METHODS[$proto]}

    if [[ "$method" == "haproxy" ]]; then
      cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${proto}_front
    bind *:${local_port}
    default_backend ${proto}_back

backend ${proto}_back
    balance roundrobin
    server ${proto}_srv ${remote_ip}:${remote_port} check
EOF
    fi
  done

  systemctl restart haproxy || true

  # تنظیم فایروال
  echo "🛡 Configuring firewall..."
  for proto in "${!PORTS_LOCAL[@]}"; do
    ufw allow "${PORTS_LOCAL[$proto]}"
  done
  ufw --force enable
}

# راه‌اندازی UDP tunnels
setup_udp() {
  echo "🌀 Setting up UDP tunnels for OpenVPN if needed..."
  for proto in "${!UDP_METHODS[@]}"; do
    if [[ "${UDP_METHODS[$proto]}" == "udp2raw" ]]; then
      local_port=${PORTS_LOCAL[$proto]}
      remote_ip=${PORTS_REMOTE[$proto]}
      remote_port=${PROTO_TYPES[$proto]}

      # نصب udp2raw در صورت نبود
      if ! command -v udp2raw &>/dev/null; then
        echo "Installing udp2raw..."
        curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/download/20190719.0/udp2raw_binaries.tar.gz | tar -xz -C /usr/local/bin/
        chmod +x /usr/local/bin/udp2raw_amd64
        ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw
      fi

      # اجرای udp2raw به عنوان سرویس systemd
      cat > /etc/systemd/system/udp2raw-${proto}.service <<EOF
[Unit]
Description=udp2raw tunnel for $proto
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l0.0.0.0:${local_port} -r ${remote_ip}:${remote_port} --raw-mode faketcp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable udp2raw-${proto}.service
      systemctl start udp2raw-${proto}.service
    fi
  done
}

# نصب اولیه و اجرای همه مراحل
install_prereqs
check_haproxy_version
enable_ip_forwarding
generate_config
setup_udp

echo -e "\n🎉 Installation complete! Active tunnels:\n"
for proto in "${!PORTS_LOCAL[@]}"; do
  echo "- $proto: local port ${PORTS_LOCAL[$proto]} -> remote ${PORTS_REMOTE[$proto]}:${PROTO_TYPES[$proto]} via ${UDP_METHODS[$proto]}"
done

exit 0
