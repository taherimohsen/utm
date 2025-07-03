#!/bin/bash
# Ultimate Tunnel Manager (UTM) - Install Script
set -euo pipefail

# --- توابع کمکی ---

log() { echo -e "\e[1;36m[UTM]\e[0m $*"; }

# چک نصب بسته
check_install_pkg() {
  dpkg -s "$1" &>/dev/null || {
    log "Installing package $1 ..."
    apt-get update -y
    apt-get install -y "$1"
  }
}

# اجرای ssh با کلید یا پسورد
ssh_exec() {
  local host=$1 cmd=$2 user=$3 pass=$4 keyfile=$5
  if [[ -n "$keyfile" ]]; then
    ssh -i "$keyfile" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$host" "$cmd"
  else
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$host" "$cmd"
  fi
}

scp_copy() {
  local host=$1 src=$2 dest=$3 user=$4 pass=$5 keyfile=$6
  if [[ -n "$keyfile" ]]; then
    scp -i "$keyfile" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src" "$user@$host:$dest"
  else
    sshpass -p "$pass" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src" "$user@$host:$dest"
  fi
}

# گرفتن IPهای دامنه
resolve_ips() {
  local domain=$1
  dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+'
}

# --- شروع اسکریپت ---

clear
log "Welcome to Ultimate Tunnel Manager (UTM) Installer"
log "Make sure you run this script as root."

# نیازمندی‌ها
check_install_pkg sshpass
check_install_pkg haproxy
check_install_pkg ipvsadm
check_install_pkg dig
check_install_pkg curl

# فعالسازی ip_forward
sysctl -w net.ipv4.ip_forward=1

read -rp "Enter unique name for this Iranian server (e.g. iran1): " IRAN_NODE

read -rp "Enter Iranian server IP (the IP of this machine): " IRAN_IP

read -rp "Enter comma-separated foreign server domains or IPs (e.g. ssh.domain.com,1.2.3.4): " FOREIGN_RAW

IFS=',' read -ra FOREIGN_HOSTS <<< "$FOREIGN_RAW"

# گرفتن مشخصات اتصال به هر سرور خارجی
declare -A FOREIGN_USER FOREIGN_PASS FOREIGN_KEY

for host in "${FOREIGN_HOSTS[@]}"; do
  echo
  log "Configuring SSH access to foreign server: $host"

  read -rp "SSH username for $host (default: root): " user
  user=${user:-root}

  read -rp "Use SSH key for $host? (y/N): " usekey
  if [[ "$usekey" =~ ^[Yy]$ ]]; then
    read -rp "Path to SSH private key for $host (default ~/.ssh/id_rsa): " keyfile
    keyfile=${keyfile:-~/.ssh/id_rsa}
    FOREIGN_KEY[$host]="$keyfile"
    FOREIGN_PASS[$host]=""
  else
    read -rsp "Password for $user@$host: " pass
    echo
    FOREIGN_PASS[$host]="$pass"
    FOREIGN_KEY[$host]=""
  fi
  FOREIGN_USER[$host]="$user"
done

# پروتکل‌ها و پورت‌ها
declare -A ENABLED PROT_PORT TRANS_METHOD

PROTOCOLS=(ssh vless vmess openvpn)
for proto in "${PROTOCOLS[@]}"; do
  read -rp "Enable tunnel for $proto? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    case $proto in
      ssh) defport=4234;;
      vless) defport=41369;;
      vmess) defport=41374;;
      openvpn) defport=42347;;
      *) defport=0;;
    esac
    read -rp "Port for $proto (default $defport): " port
    port=${port:-$defport}
    ENABLED[$proto]=1
    PROT_PORT[$proto]=$port

    echo "Transport method for $proto:"
    echo "1) TCP via HAProxy (default)"
    echo "2) UDP via IPVS + udp2raw on foreign servers"
    read -rp "Select transport [1-2]: " tmeth
    if [[ "$tmeth" == "2" ]]; then
      TRANS_METHOD[$proto]="udp"
    else
      TRANS_METHOD[$proto]="tcp"
    fi
  fi
done

if [[ ${#ENABLED[@]} -eq 0 ]]; then
  log "No protocols enabled. Exiting."
  exit 1
fi

# --- نصب udp2raw روی سرورهای خارجی ---

install_udp2raw_foreign() {
  local host=$1 user=$2 pass=$3 keyfile=$4
  log "Installing udp2raw on foreign server $host..."
  ssh_exec "$host" "command -v udp2raw >/dev/null 2>&1" "$user" "$pass" "$keyfile" || {
    ssh_exec "$host" "apt-get update && apt-get install -y curl && curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/latest/download/udp2raw_amd64" "$user" "$pass" "$keyfile"
    ssh_exec "$host" "chmod +x udp2raw_amd64 && mv udp2raw_amd64 /usr/local/bin/udp2raw" "$user" "$pass" "$keyfile"
  }
}

# --- تنظیم IPVS روی ایران ---

setup_ipvs() {
  log "Setting up IPVS on Iranian server..."
  modprobe ip_vs || true
  modprobe ip_vs_rr || true
  ipvsadm -C || true

  for proto in "${!ENABLED[@]}"; do
    if [[ "${TRANS_METHOD[$proto]}" == "udp" ]]; then
      local port=${PROT_PORT[$proto]}
      ipvsadm -A -u 0.0.0.0:$port -s rr
      for fhost in "${FOREIGN_HOSTS[@]}"; do
        for fip in $(resolve_ips "$fhost"); do
          ipvsadm -a -u 0.0.0.0:$port -r $fip:$port -m
        done
      done
      log "IPVS configured for UDP $proto on port $port"
    fi
  done
}

# --- تولید فایل systemd برای udp2raw ---

create_udp2raw_service() {
  local host=$1 proto=$2 port=$3 user=$4 pass=$5 keyfile=$6 svcname="udp2raw-${IRAN_NODE}-${proto}"

  local foreign_ip="$host"
  # در اینجا فرض شده udp2raw سرور ایران رو به localhost روی پورت میبنده
  # در صورت نیاز میتونید IP و پورت واقعی ایران رو وارد کنید.

  local iran_ip="$IRAN_IP"

  local srvfile="/etc/systemd/system/$svcname.service"

  local service_content="[Unit]
Description=UTM udp2raw $proto $IRAN_NODE
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l0.0.0.0:$port -r $iran_ip:$port --raw-mode faketcp --timeout 30
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target"

  # انتقال فایل به سرور خارجی
  echo "$service_content" > /tmp/$svcname.service

  scp_copy "$host" "/tmp/$svcname.service" "$srvfile" "$user" "$pass" "$keyfile"
  ssh_exec "$host" "systemctl daemon-reload && systemctl enable $svcname && systemctl restart $svcname" "$user" "$pass" "$keyfile"

  rm -f /tmp/$svcname.service
  log "udp2raw service created and started on $host for $proto"
}

# --- تولید haproxy config برای TCP ---

generate_haproxy_cfg() {
  log "Generating haproxy config..."

  cat > /etc/haproxy/haproxy.cfg <<EOF
global
  log /dev/log local0
  maxconn 4096
  daemon

defaults
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
EOF

  for proto in "${!ENABLED[@]}"; do
    if [[ "${TRANS_METHOD[$proto]}" == "tcp" ]]; then
      local port=${PROT_PORT[$proto]}
      echo -e "\nfrontend ${proto}_in\n  bind *:$port\n  default_backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
      echo "backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
      for fhost in "${FOREIGN_HOSTS[@]}"; do
        for fip in $(resolve_ips "$fhost"); do
          echo "  server ${proto}_$fip $fip:$port check" >> /etc/haproxy/haproxy.cfg
        done
      done
    fi
  done

  systemctl restart haproxy
  log "HAProxy restarted."
}

# --- Main Execution ---

log "Starting tunnel setup..."

# نصب udp2raw روی سرورهای خارجی
for fhost in "${FOREIGN_HOSTS[@]}"; do
  install_udp2raw_foreign "$fhost" "${FOREIGN_USER[$fhost]}" "${FOREIGN_PASS[$fhost]}" "${FOREIGN_KEY[$fhost]}"
done

# راه‌اندازی IPVS روی ایران
setup_ipvs

# تولید کانفیگ HAProxy برای TCP
generate_haproxy_cfg

# ساخت سرویس udp2raw روی سرورهای خارجی برای هر پروتکل UDP
for proto in "${!ENABLED[@]}"; do
  if [[ "${TRANS_METHOD[$proto]}" == "udp" ]]; then
    for fhost in "${FOREIGN_HOSTS[@]}"; do
      create_udp2raw_service "$fhost" "$proto" "${PROT_PORT[$proto]}" "${FOREIGN_USER[$fhost]}" "${FOREIGN_PASS[$fhost]}" "${FOREIGN_KEY[$fhost]}"
    done
  fi
done

# کران‌تب برای ریست سرویس‌ها هر 6 ساعت
(crontab -l 2>/dev/null | grep -v utm_restart) > /tmp/crontab.bak || true
echo "0 */6 * * * systemctl restart haproxy" >> /tmp/crontab.bak
for proto in "${!ENABLED[@]}"; do
  if [[ "${TRANS_METHOD[$proto]}" == "udp" ]]; then
    for fhost in "${FOREIGN_HOSTS[@]}"; do
      svcname="udp2raw-${IRAN_NODE}-${proto}"
      echo "0 */6 * * * sshpass -p '${FOREIGN_PASS[$fhost]}' ssh -o StrictHostKeyChecking=no ${FOREIGN_USER[$fhost]}@${fhost} systemctl restart $svcname" >> /tmp/crontab.bak
    done
  fi
done
crontab /tmp/crontab.bak
rm -f /tmp/crontab.bak

log "Tunnel setup complete!"
