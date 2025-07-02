#!/bin/bash
set -euo pipefail
clear
echo -e "\e[1;36mUltimate Tunnel Manager (UTM) - Setup\e[0m"
echo "=================================================="

# ابزار کمکی برای گرفتن IP ها از دامنه
resolve_ips() {
  local domain=$1
  dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+'
}

# گرفتن یوزرنیم و پسورد یا کلید SSH برای هر IP سرور خارجی
get_foreign_auth() {
  declare -n users=$1
  declare -n passes=$2
  declare -n keys=$3

  for fhost in "${FOREIGN_HOSTS[@]}"; do
    ips=($(resolve_ips "$fhost"))
    for ip in "${ips[@]}"; do
      echo -e "\nEnter SSH credentials for foreign server IP: $ip"
      read -rp "SSH username (default root): " user
      user=${user:-root}
      users["$ip"]=$user

      echo "Select authentication method for $user@$ip:"
      echo "1) Password"
      echo "2) SSH Key"
      read -rp "Choice [1-2]: " auth_choice
      if [[ "$auth_choice" == "2" ]]; then
        read -rp "Path to SSH private key (default ~/.ssh/id_rsa): " keypath
        keypath=${keypath:-~/.ssh/id_rsa}
        keys["$ip"]=$keypath
        passes["$ip"]=""
      else
        read -rsp "Enter password for $user@$ip: " pass
        echo
        passes["$ip"]=$pass
        keys["$ip"]=""
      fi
    done
  done
}

# توابع ssh و scp با توجه به یوزر پسورد یا کلید هر IP
ssh_foreign() {
  local host=$1 cmd=$2
  local user=${FOREIGN_USERS[$host]:-root}
  local pass=${FOREIGN_PASS[$host]:-}
  local key=${FOREIGN_KEY[$host]:-}

  if [[ -n "$key" ]]; then
    ssh -i "$key" -o StrictHostKeyChecking=no "$user@$host" "$cmd"
  else
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$host" "$cmd"
  fi
}

scp_foreign() {
  local host=$1 localfile=$2 remotefile=$3
  local user=${FOREIGN_USERS[$host]:-root}
  local pass=${FOREIGN_PASS[$host]:-}
  local key=${FOREIGN_KEY[$host]:-}

  if [[ -n "$key" ]]; then
    scp -i "$key" -o StrictHostKeyChecking=no "$localfile" "$user@$host":"$remotefile"
  else
    sshpass -p "$pass" scp -o StrictHostKeyChecking=no "$localfile" "$user@$host":"$remotefile"
  fi
}

# --- شروع setup ---

read -rp "Enter unique name for this Iranian server (e.g. iran1): " IRAN_NODE
read -rp "Enter comma-separated foreign server hostnames or IPs (e.g. ssh.example.com,185.44.1.3): " FOREIGN_HOSTS_RAW

IFS=',' read -ra FOREIGN_HOSTS <<< "$FOREIGN_HOSTS_RAW"

declare -A FOREIGN_USERS FOREIGN_PASS FOREIGN_KEY

# گرفتن اعتبارنامه SSH برای هر IP خارجی
get_foreign_auth FOREIGN_USERS FOREIGN_PASS FOREIGN_KEY

declare -A ENABLED PROT_PORT TRANS_METHOD
PROTOCOLS=(ssh vless vmess openvpn)

for proto in "${PROTOCOLS[@]}"; do
  read -rp "Enable tunnel for $proto? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "Port for $proto: " port
    ENABLED[$proto]=1
    PROT_PORT[$proto]=$port

    echo "Transport method for $proto:"
    echo "1) TCP via HAProxy (default)"
    echo "2) UDP via iptables"
    echo "3) UDP via socat"
    echo "4) UDP via udp2raw"
    echo "5) UDP via IPVS"
    read -rp "Select [1-5]: " method
    case $method in
      2) TRANS_METHOD[$proto]="iptables";;
      3) TRANS_METHOD[$proto]="socat";;
      4) TRANS_METHOD[$proto]="udp2raw";;
      5) TRANS_METHOD[$proto]="ipvs";;
      *) TRANS_METHOD[$proto]="haproxy";;
    esac
  fi
done

# بررسی و نصب پیش‌نیازها روی ایران
install_prereqs_iran() {
  echo "[Iran] Installing prerequisites..."
  apt-get update
  apt-get install -y haproxy ipvsadm iproute2 sshpass socat curl net-tools
  # udp2raw نصب دستی:
  if ! command -v udp2raw >/dev/null 2>&1; then
    echo "[Iran] Installing udp2raw..."
    curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/download/20190719.0/udp2raw_binaries.tar.gz | tar -xz -C /usr/local/bin/
    chmod +x /usr/local/bin/udp2raw_amd64
    ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw
  fi
}

# نصب پیش‌نیازها روی سرور خارج با ssh
install_prereqs_foreign() {
  local ip=$1
  local user=${FOREIGN_USERS[$ip]}
  local pass=${FOREIGN_PASS[$ip]}
  local key=${FOREIGN_KEY[$ip]}
  echo "[Foreign $ip] Installing prerequisites..."
  local install_cmd="apt-get update && apt-get install -y haproxy ipvsadm iproute2 sshpass socat curl net-tools"
  if [[ -z "$key" ]]; then
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$ip" "$install_cmd"
  else
    ssh -i "$key" -o StrictHostKeyChecking=no "$user@$ip" "$install_cmd"
  fi
}

# ساخت فایل‌های کانفیگ haproxy روی ایران
gen_haproxy_config() {
  echo "[Iran] Generating haproxy config..."
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
    [[ ${TRANS_METHOD[$proto]} == "haproxy" ]] || continue
    port=${PROT_PORT[$proto]}
    echo -e "\nfrontend ${proto}_in\n  bind *:$port\n  default_backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
    echo "backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
    for fhost in "${FOREIGN_HOSTS[@]}"; do
      ips=($(resolve_ips "$fhost"))
      for ip in "${ips[@]}"; do
        echo "  server ${proto}_$ip $ip:$port check" >> /etc/haproxy/haproxy.cfg
      done
    done
  done

  systemctl restart haproxy || true
  (crontab -l 2>/dev/null; echo "0 */6 * * * systemctl restart haproxy") | crontab -
}

# ساخت و انتقال کانفیگ ipvs روی ایران و سرورهای خارج
setup_ipvs_tunnel() {
  local proto=$1
  local port=${PROT_PORT[$proto]}
  echo "[Iran] Setting up IPVS for $proto on port $port..."
  modprobe ip_vs ip_vs_rr || true
  ipvsadm -C
  ipvsadm -A -u 0.0.0.0:$port -s rr
  for fhost in "${FOREIGN_HOSTS[@]}"; do
    ips=($(resolve_ips "$fhost"))
    for ip in "${ips[@]}"; do
      ipvsadm -a -u 0.0.0.0:$port -r $ip:$port -m
    done
  done

  # ساخت اسکریپت ریست IPVS برای سرور ایران
  cat > /opt/utm/ipvs-$IRAN_NODE-$proto.sh <<EOF
#!/bin/bash
modprobe ip_vs
modprobe ip_vs_rr
ipvsadm -C
ipvsadm -A -u 0.0.0.0:$port -s rr
EOF
  for fhost in "${FOREIGN_HOSTS[@]}"; do
    ips=($(resolve_ips "$fhost"))
    for ip in "${ips[@]}"; do
      echo "ipvsadm -a -u 0.0.0.0:$port -r $ip:$port -m" >> /opt/utm/ipvs-$IRAN_NODE-$proto.sh
    done
  done
  chmod +x /opt/utm/ipvs-$IRAN_NODE-$proto.sh
  (crontab -l 2>/dev/null; echo "*/30 * * * * /opt/utm/ipvs-$IRAN_NODE-$proto.sh") | crontab -

  # انتقال و اجرای اسکریپت IPVS روی هر سرور خارجی
  for fhost in "${FOREIGN_HOSTS[@]}"; do
    ips=($(resolve_ips "$fhost"))
    for ip in "${ips[@]}"; do
      echo "[Foreign $ip] Sending IPVS reset script for $proto..."
      scp_foreign "$ip" "/opt/utm/ipvs-$IRAN_NODE-$proto.sh" "/opt/utm/ipvs-$IRAN_NODE-$proto.sh"
      ssh_foreign "$ip" "chmod +x /opt/utm/ipvs-$IRAN_NODE-$proto.sh && /opt/utm/ipvs-$IRAN_NODE-$proto.sh && (crontab -l 2>/dev/null; echo '*/30 * * * * /opt/utm/ipvs-$IRAN_NODE-$proto.sh') | crontab -"
    done
  done
}

# نصب udp2raw اگر انتخاب شده و انتقال به خارج
install_udp2raw_and_setup() {
 echo "[Iran] Installing udp2raw..."
  URL="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"
  curl -L "$URL" -o /tmp/udp2raw_binaries.tar.gz
  tar -xzf /tmp/udp2raw_binaries.tar.gz -C /usr/local/bin/
  chmod +x /usr/local/bin/udp2raw_amd64
  ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw
  rm -f /tmp/udp2raw_binaries.tar.gz

  for proto in "${!ENABLED[@]}"; do
    [[ ${TRANS_METHOD[$proto]} != "udp2raw" ]] && continue
    port=${PROT_PORT[$proto]}
    for fhost in "${FOREIGN_HOSTS[@]}"; do
      ips=($(resolve_ips "$fhost"))
      for ip in "${ips[@]}"; do
        SERVICE="udp2raw-${IRAN_NODE}-${proto}"
        TMPFILE="/tmp/$SERVICE.service"
        cat > "$TMPFILE" <<EOL
[Unit]
Description=UTM UDP2RAW $proto $IRAN_NODE
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l0.0.0.0:$port -r $ip:$port --raw-mode faketcp
Restart=always

[Install]
WantedBy=multi-user.target
EOL
        scp_foreign "$ip" "$TMPFILE" "/etc/systemd/system/$SERVICE.service"
        ssh_foreign "$ip" "systemctl daemon-reexec && systemctl enable $SERVICE && systemctl restart $SERVICE"
      done
    done
  done
}

# --- شروع عملیات ---

install_prereqs_iran

for ip in "${!FOREIGN_USERS[@]}"; do
  install_prereqs_foreign "$ip"
done

# تنظیم IPVS برای پروتکل های انتخابی روی ایران و سرورهای خارجی
for proto in "${!ENABLED[@]}"; do
  case ${TRANS_METHOD[$proto]} in
    ipvs) setup_ipvs_tunnel "$proto" ;;
  esac
done

# تولید و راه‌اندازی HAProxy روی ایران
gen_haproxy_config

# نصب و راه اندازی udp2raw اگر انتخاب شده
install_udp2raw_and_setup

echo -e "\n✅ Setup complete for Iranian node: $IRAN_NODE"
echo "Configured tunnels:"
for proto in "${!ENABLED[@]}"; do
  echo "- $proto on port ${PROT_PORT[$proto]} via ${TRANS_METHOD[$proto]}"
done
