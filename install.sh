#!/bin/bash
set -euo pipefail

clear
echo -e "\e[1;36mUltimate Tunnel Manager (UTM)\e[0m - Automated Tunnel Deployment"
echo "=================================================================="

read -rp "Enter a unique name for this Iranian server (e.g. iran1): " IRAN_NODE

echo -e "\n🌍 Enter comma-separated foreign server hostnames or IPs (e.g. ssh.example.com,185.44.1.3):"
read -rp "Foreign nodes: " FOREIGN_HOSTS_RAW
IFS=',' read -ra FOREIGN_HOSTS <<< "$FOREIGN_HOSTS_RAW"

declare -A FOREIGN_SSH_USER FOREIGN_SSH_PASS

# Get SSH credentials for each resolved IP
for host in "${FOREIGN_HOSTS[@]}"; do
  IPs=$(dig +short "$host" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+')
  for ip in $IPs; do
    echo -e "\n🔐 SSH credentials for $ip"
    read -rp "Username [default: root]: " u
    FOREIGN_SSH_USER[$ip]=${u:-root}
    read -rsp "Password for ${FOREIGN_SSH_USER[$ip]}@$ip: " p
    echo
    FOREIGN_SSH_PASS[$ip]=$p
  done
done

declare -A ENABLED PROT_PORT TRANS_METHOD
PROTOCOLS=(ssh vless vmess openvpn)
for proto in "${PROTOCOLS[@]}"; do
  read -rp "Enable tunnel for $proto? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "Port for $proto (your desired port): " port
    ENABLED[$proto]=1
    PROT_PORT[$proto]=$port

    echo "Transport method for $proto:"
    echo "1) TCP via HAProxy (default)"
    echo "2) UDP via iptables"
    echo "3) UDP via socat"
    echo "4) UDP via udp2raw"
    echo "5) UDP via IPVS (recommended for OpenVPN)"
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

install_udp2raw() {
  echo "[Iran] Installing udp2raw..."
  curl -L -o /usr/local/bin/udp2raw https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200729.0/udp2raw_amd64
  chmod +x /usr/local/bin/udp2raw
}

resolve_ips() {
  local domain=$1
  dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+'
}

ssh_foreign() {
  local ip=$1 cmd=$2
  sshpass -p "${FOREIGN_SSH_PASS[$ip]}" ssh -o StrictHostKeyChecking=no "${FOREIGN_SSH_USER[$ip]}@$ip" "$cmd"
}

scp_foreign() {
  local ip=$1 localfile=$2 remotefile=$3
  sshpass -p "${FOREIGN_SSH_PASS[$ip]}" scp -o StrictHostKeyChecking=no "$localfile" "${FOREIGN_SSH_USER[$ip]}@$ip":"$remotefile"
}

setup_ipvs() {
  apt install -y ipvsadm
  modprobe ip_vs
  modprobe ip_vs_rr
  local proto=$1
  local port=${PROT_PORT[$proto]}
  local script="/opt/utm/ipvs-${IRAN_NODE}-${proto}.sh"
  mkdir -p /opt/utm
  cat > "$script" <<EOF
#!/bin/bash
ipvsadm -C
ipvsadm -A -u 0.0.0.0:$port -s rr
EOF
  for h in "${FOREIGN_HOSTS[@]}"; do
    for ip in $(resolve_ips "$h"); do
      echo "ipvsadm -a -u 0.0.0.0:$port -r $ip:$port -m" >> "$script"
    done
  done
  chmod +x "$script"
  bash "$script"
  (crontab -l 2>/dev/null; echo "*/30 * * * * $script") | crontab -
}

gen_haproxy() {
  apt install -y haproxy
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
  systemctl restart haproxy
  (crontab -l 2>/dev/null; echo "0 */6 * * * systemctl restart haproxy") | crontab -
}

# Begin setup
for proto in "${!ENABLED[@]}"; do
  case ${TRANS_METHOD[$proto]} in
    ipvs)
      setup_ipvs "$proto"
      ;;
    haproxy)
      ;;
    udp2raw)
      install_udp2raw
      for h in "${FOREIGN_HOSTS[@]}"; do
        for ip in $(resolve_ips "$h"); do
          SERVICE="udp2raw-${IRAN_NODE}-${proto}"
          ssh_foreign "$ip" "curl -L -o /usr/local/bin/udp2raw https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200729.0/udp2raw_amd64 && chmod +x /usr/local/bin/udp2raw"
          ssh_foreign "$ip" "cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=UTM udp2raw $proto $IRAN_NODE
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -s -l0.0.0.0:$port -r 127.0.0.1:$port --raw-mode faketcp
Restart=always

[Install]
WantedBy=multi-user.target
EOF
          systemctl daemon-reexec && systemctl enable $SERVICE && systemctl restart $SERVICE"
        done
      done
      ;;
  esac
done

gen_haproxy

echo -e "\n✅ Tunnel setup complete"
