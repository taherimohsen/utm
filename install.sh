#!/bin/bash
# Ultimate Tunnel Manager (UTM) - Full Automation Script
set -euo pipefail

INSTALL_DIR="/opt/utm"
mkdir -p "$INSTALL_DIR"

clear
echo -e "\e[1;36mUltimate Tunnel Manager (UTM)\e[0m - Automated Tunnel Setup"
echo "=============================================================="

# --- توابع کمکی ---
resolve_ips() {
  local domain="$1"
  dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+'
}

ssh_foreign() {
  local host=$1 cmd=$2
  if [[ "$SSH_METHOD" == "2" ]]; then
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER"@"$host" "$cmd"
  else
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$host" "$cmd"
  fi
}

scp_foreign() {
  local host=$1 localfile=$2 remotefile=$3
  if [[ "$SSH_METHOD" == "2" ]]; then
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$localfile" "$SSH_USER"@"$host":"$remotefile"
  else
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$localfile" "$SSH_USER"@"$host":"$remotefile"
  fi
}

install_tools() {
  local tools=("$@")
  apt-get update
  apt-get install -y "${tools[@]}"
}

install_udp2raw() {
  echo "[*] Installing udp2raw..."
  curl -sL https://github.com/wangyu-/udp2raw-tunnel/releases/download/20190719.0/udp2raw_binaries.tar.gz | tar -xz -C /usr/local/bin/
  chmod +x /usr/local/bin/udp2raw_amd64
  ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw
}

# --- پرسش‌های اصلی ---
read -rp "Enter unique name for this Iranian server (e.g. iran1): " IRAN_NODE

echo "Enter comma-separated foreign server hostnames or IPs (e.g. ssh.example.com,185.44.1.3):"
read -rp "Foreign nodes: " FOREIGN_HOSTS_RAW
IFS=',' read -ra FOREIGN_HOSTS <<< "$FOREIGN_HOSTS_RAW"

echo "SSH method for foreign servers:"
echo "1) Password (default)"
echo "2) SSH Key"
read -rp "Select [1-2]: " SSH_METHOD
SSH_METHOD=${SSH_METHOD:-1}
if [[ "$SSH_METHOD" == "2" ]]; then
  read -rp "Path to SSH private key (default ~/.ssh/id_rsa): " SSH_KEY
  SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
else
  read -rp "SSH username for foreign servers (default root): " SSH_USER
  SSH_USER=${SSH_USER:-root}
fi

declare -A ENABLED PROT_PORT TRANS_METHOD

PROTOCOLS=(ssh vless vmess openvpn)

for proto in "${PROTOCOLS[@]}"; do
  read -rp "Enable tunnel for $proto? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    default_port=""
    case $proto in
      ssh) default_port=4234 ;;
      vless) default_port=41369 ;;
      vmess) default_port=41374 ;;
      openvpn) default_port=42347 ;;
    esac
    read -rp "Port for $proto (default $default_port): " port
    port=${port:-$default_port}
    ENABLED[$proto]=1
    PROT_PORT[$proto]=$port

    echo "Transport method for $proto:"
    echo "1) TCP via HAProxy (default)"
    echo "2) UDP via IPVS"
    echo "3) UDP via iptables"
    echo "4) UDP via socat"
    echo "5) UDP via udp2raw"
    read -rp "Select [1-5]: " method
    case $method in
      2) TRANS_METHOD[$proto]="ipvs" ;;
      3) TRANS_METHOD[$proto]="iptables" ;;
      4) TRANS_METHOD[$proto]="socat" ;;
      5) TRANS_METHOD[$proto]="udp2raw" ;;
      *) TRANS_METHOD[$proto]="haproxy" ;;
    esac
  fi
done

# --- نصب ابزارها روی سرور ایران ---
echo "[*] Installing required tools on Iranian server..."
tools_to_install=(haproxy ipvsadm sshpass socat curl dnsutils)
if [[ " ${TRANS_METHOD[@]} " =~ "udp2raw" ]]; then
  install_udp2raw
fi
install_tools "${tools_to_install[@]}"

# --- تعریف توابع کانفیگ ---

setup_ipvs() {
  local proto=$1
  local port=${PROT_PORT[$proto]}
  local file="$INSTALL_DIR/ipvs-${IRAN_NODE}-${proto}.sh"

  echo "[*] Setting up IPVS for $proto on port $port"

  modprobe ip_vs
  modprobe ip_vs_rr

  cat > "$file" <<EOF
#!/bin/bash
modprobe ip_vs
modprobe ip_vs_rr
ipvsadm -C
ipvsadm -A -u 0.0.0.0:$port -s rr
EOF

  for f in "${FOREIGN_HOSTS[@]}"; do
    for ip in $(resolve_ips "$f"); do
      echo "ipvsadm -a -u 0.0.0.0:$port -r $ip:$port -m" >> "$file"
    done
  done
  chmod +x "$file"
  bash "$file"
  (crontab -l 2>/dev/null | grep -v "$file"; echo "*/30 * * * * $file") | crontab -

  # Deploy روی سرورهای خارجی
  echo "[*] Deploying IPVS setup to foreign servers..."
  for f in "${FOREIGN_HOSTS[@]}"; do
    for ip in $(resolve_ips "$f"); do
      echo "[*] Configuring IPVS on $ip"
      ssh_foreign "$ip" "apt-get update && apt-get install -y ipvsadm; modprobe ip_vs; modprobe ip_vs_rr"
      scp_foreign "$ip" "$file" "/opt/utm/ipvs-${IRAN_NODE}-${proto}.sh"
      ssh_foreign "$ip" "chmod +x /opt/utm/ipvs-${IRAN_NODE}-${proto}.sh"
      ssh_foreign "$ip" "/opt/utm/ipvs-${IRAN_NODE}-${proto}.sh"
      ssh_foreign "$ip" "(crontab -l 2>/dev/null | grep -v ipvs-${IRAN_NODE}-${proto}.sh; echo '*/30 * * * * /opt/utm/ipvs-${IRAN_NODE}-${proto}.sh') | crontab -"
      ssh_foreign "$ip" "if [ -f /etc/rc.local ]; then grep -q ipvs-${IRAN_NODE}-${proto}.sh /etc/rc.local || echo '/opt/utm/ipvs-${IRAN_NODE}-${proto}.sh &' >> /etc/rc.local && chmod +x /etc/rc.local; fi"
    done
  done
}

setup_haproxy() {
  echo "[*] Generating HAProxy config..."
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
    for h in "${FOREIGN_HOSTS[@]}"; do
      for ip in $(resolve_ips "$h"); do
        echo "  server ${proto}_$ip $ip:$port check" >> /etc/haproxy/haproxy.cfg
      done
    done
  done
  systemctl restart haproxy || true
  (crontab -l 2>/dev/null; echo "0 */6 * * * systemctl restart haproxy") | crontab -
}

setup_udp2raw() {
  echo "[*] Installing and setting up udp2raw..."
  install_udp2raw

  for proto in "${!ENABLED[@]}"; do
    [[ ${TRANS_METHOD[$proto]} != "udp2raw" ]] && continue
    port=${PROT_PORT[$proto]}
    for f in "${FOREIGN_HOSTS[@]}"; do
      for ip in $(resolve_ips "$f"); do
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

setup_socat() {
  echo "[*] Installing and setting up socat..."

  install_tools socat

  for proto in "${!ENABLED[@]}"; do
    [[ ${TRANS_METHOD[$proto]} != "socat" ]] && continue
    port=${PROT_PORT[$proto]}
    for f in "${FOREIGN_HOSTS[@]}"; do
      for ip in $(resolve_ips "$f"); do
        SERVICE="socat-${IRAN_NODE}-${proto}"
        TMPFILE="/tmp/$SERVICE.service"

        cat > "$TMPFILE" <<EOL
[Unit]
Description=UTM SOCAT $proto $IRAN_NODE
After=network.target

[Service]
ExecStart=/usr/bin/socat UDP-LISTEN:$port,fork UDP:$ip:$port
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

setup_iptables() {
  echo "[*] Installing and setting up iptables for UDP forwarding..."

  install_tools iptables-persistent

  for proto in "${!ENABLED[@]}"; do
    [[ ${TRANS_METHOD[$proto]} != "iptables" ]] && continue
    port=${PROT_PORT[$proto]}
    for f in "${FOREIGN_HOSTS[@]}"; do
      for ip in $(resolve_ips "$f"); do
        echo "[*] Adding iptables rules for $proto to forward UDP port $port to $ip"
        iptables -t nat -A PREROUTING -p udp --dport "$port" -j DNAT --to-destination "$ip:$port"
        iptables -t nat -A POSTROUTING -p udp -d "$ip" --dport "$port" -j MASQUERADE
      done
    done
  done

  netfilter-persistent save
}

# --- شروع نصب ---
for proto in "${!ENABLED[@]}"; do
  case ${TRANS_METHOD[$proto]} in
    ipvs) setup_ipvs "$proto" ;;
    haproxy) ;;
    udp2raw) setup_udp2raw ;;
    socat) setup_socat ;;
    iptables) setup_iptables ;;
  esac
done

setup_haproxy

echo -e "\n✅ Setup complete for $IRAN_NODE"
for proto in "${!ENABLED[@]}"; do
  echo "- $proto on port ${PROT_PORT[$proto]} via ${TRANS_METHOD[$proto]}"
done

exit 0
