#!/bin/bash
# install.sh - Ultimate Tunnel Manager with full automation
set -euo pipefail

clear
echo -e "\e[1;36mUltimate Tunnel Manager (UTM)\e[0m - Automated Tunnel Deployment"
echo "=================================================================="

# 🧭 Main menu
menu() {
  echo ""
  echo "1) Install / Configure Tunnel"
  echo "2) Uninstall Tunnel (Clean)"
  echo "3) Show Tunnel Status"
  echo "4) Exit"
  echo ""
  read -rp "Select an option [1-4]: " opt
  case $opt in
    1) setup_tunnel;;
    2) uninstall_tunnel;;
    3) show_status;;
    *) exit 0;;
  esac
}

# 📡 Setup Tunnel
setup_tunnel() {
  read -rp "Enter unique name for this Iranian server (e.g. iran1): " IRAN_NODE

  echo "\n🌍 Enter comma-separated foreign server hostnames or IPs (e.g. ssh.example.com,185.44.1.3):"
  read -rp "Foreign nodes: " FOREIGN_HOSTS_RAW
  IFS=',' read -ra FOREIGN_HOSTS <<< "$FOREIGN_HOSTS_RAW"

  echo "\n🔐 SSH method for foreign server(s):"
  echo "1) Password (default)"
  echo "2) SSH Key"
  read -rp "Select [1-2]: " SSH_METHOD
  SSH_METHOD=${SSH_METHOD:-1}

  if [[ "$SSH_METHOD" == "2" ]]; then
    read -rp "Path to SSH private key (default ~/.ssh/id_rsa): " SSH_KEY
    SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
  else
    read -rp "Username for SSH login (default: root): " SSH_USER
    SSH_USER=${SSH_USER:-root}
    read -rsp "Password for $SSH_USER: " SSH_PASS
    echo
  fi

  declare -A ENABLED PROT_PORT TRANS_METHOD
  PROTOCOLS=(ssh vless vmess openvpn)
  for proto in "${PROTOCOLS[@]}"; do
    read -rp "Enable tunnel for $proto? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      read -rp "Port for $proto (default suggested): " port
      case $proto in
        ssh) port=${port:-4234};;
        vless) port=${port:-41369};;
        vmess) port=${port:-41374};;
        openvpn) port=${port:-42347};;
      esac
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

  resolve_ips() {
    local domain=$1
    dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+'
  }

  ssh_foreign() {
    local host=$1 cmd=$2
    if [[ "$SSH_METHOD" == "2" ]]; then
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$host" "$cmd"
    else
      sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$host" "$cmd"
    fi
  }

  scp_foreign() {
    local host=$1 localfile=$2 remotefile=$3
    if [[ "$SSH_METHOD" == "2" ]]; then
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$localfile" root@"$host":"$remotefile"
    else
      sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$localfile" "$SSH_USER"@"$host":"$remotefile"
    fi
  }

  setup_ipvs() {
    local proto=$1
    local port=${PROT_PORT[$proto]}
    local file=/opt/utm/ipvs-${IRAN_NODE}-${proto}.sh
    echo "Configuring IPVS for $proto (port $port)"
    mkdir -p /opt/utm
    cat > "$file" <<EOF
#!/bin/bash
modprobe ip_vs
modprobe ip_vs_rr
ipvsadm -C
ipvsadm -A -u 0.0.0.0:$port -s rr
EOF
    for f in "${FOREIGN_HOSTS[@]}"; do
      for ip in $(resolve_ips "$f"); do
        echo "ipvsadm -a -u 0.0.0.0:$port -r \$ip:$port -m" >> "$file"
      done
    done
    chmod +x "$file"
    (crontab -l 2>/dev/null; echo "*/30 * * * * $file") | crontab -
    grep -q "$file" /etc/rc.local || echo "$file &" >> /etc/rc.local
    bash "$file"
  }

  gen_haproxy() {
    echo "Generating HAProxy config..."
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

  install_udp2raw() {
    echo "Installing udp2raw binary..."
    curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/download/20190719.0/udp2raw_binaries.tar.gz | tar -xz -C /usr/local/bin/
    chmod +x /usr/local/bin/udp2raw_amd64
    ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw
  }

  for proto in "${!ENABLED[@]}"; do
    case ${TRANS_METHOD[$proto]} in
      ipvs) setup_ipvs "$proto";;
      haproxy) ;;
      udp2raw)
        install_udp2raw
        for f in "${FOREIGN_HOSTS[@]}"; do
          for ip in $(resolve_ips "$f"); do
            SERVICE="udp2raw-${IRAN_NODE}-${proto}"
            TMPFILE="/tmp/$SERVICE.service"
            cat > "$TMPFILE" <<EOL
[Unit]
Description=UTM UDP2RAW $proto $IRAN_NODE
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l0.0.0.0:${PROT_PORT[$proto]} -r $HOST_IP:${PROT_PORT[$proto]} --raw-mode faketcp
Restart=always

[Install]
WantedBy=multi-user.target
EOL
            scp_foreign "$ip" "$TMPFILE" "/etc/systemd/system/$SERVICE.service"
            ssh_foreign "$ip" "systemctl daemon-reexec && systemctl enable $SERVICE && systemctl restart $SERVICE"
          done
        done
        ;;
    esac
  done

  gen_haproxy
  echo -e "\n✅ Setup complete for $IRAN_NODE"
  for proto in "${!ENABLED[@]}"; do
    echo "- $proto on port ${PROT_PORT[$proto]} via ${TRANS_METHOD[$proto]}"
  done
}

uninstall_tunnel() {
  echo "🧹 Cleaning up..."
  systemctl stop haproxy || true
  systemctl disable haproxy || true
  rm -f /etc/haproxy/haproxy.cfg
  ipvsadm -C || true
  crontab -l | grep -v "/opt/utm/" | crontab -
  rm -rf /opt/utm
  echo "✅ Uninstalled UTM"
}

show_status() {
  echo "🔍 Active tunnels:"
  ss -tulnp | grep -E '4234|4136[49]|42347' || echo "No active tunnel services"
}

menu
