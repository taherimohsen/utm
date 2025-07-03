#!/bin/bash
# Ultimate Tunnel Manager - install.sh (Final Stable Version)
set -euo pipefail

echo -e "\e[1;36mUTM - Ultimate Tunnel Manager\e[0m"
echo "===================================="

function pause() { read -rp "Press Enter to continue..."; }

function install_dependencies() {
  echo "[*] Installing dependencies on Iranian server..."
  apt update && apt install -y ipvsadm curl dnsutils sshpass haproxy socat
}

function menu() {
  echo -e "\n1) Install / Configure Tunnel"
  echo "2) Uninstall"
  echo "3) Status"
  echo "4) Exit"
  read -rp "Select an option [1-4]: " opt
  case $opt in
    1) install_dependencies; setup_tunnel;;
    2) uninstall;;
    3) show_status;;
    *) exit 0;;
  esac
}

function setup_tunnel() {
  read -rp "Enter a unique name for this Iranian server (e.g. iran1): " IRAN_NODE
  read -rp "Enter comma-separated foreign domains/IPs (e.g. fo1.com,fo2.com): " HOSTS_RAW
  IFS=',' read -ra HOSTS <<< "$HOSTS_RAW"

  declare -A HOST_IPS
  declare -A CREDENTIALS

  for host in "${HOSTS[@]}"; do
    echo "[*] Resolving $host..."
    ips=$(dig +short "$host" | grep -Eo '([0-9]{1,3}\.){3}[0-9]+')
    for ip in $ips; do
      HOST_IPS[$ip]=$host
      echo -e "Enter credentials for $ip (resolved from $host):"
      read -rp " - Username: " user
      read -rsp " - Password: " pass
      echo
      CREDENTIALS[$ip]="$user:$pass"
    done
  done

  declare -A ENABLED PROT_PORT TRANS
  PROTOCOLS=(ssh vless vmess openvpn)

  for proto in "${PROTOCOLS[@]}"; do
    read -rp "Enable $proto tunnel? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || continue
    read -rp "Port for $proto: " port
    ENABLED[$proto]=1
    PROT_PORT[$proto]=$port

    echo "Transport for $proto:"
    echo "1) TCP via HAProxy"
    echo "2) UDP via iptables"
    echo "3) UDP via socat"
    echo "4) UDP via udp2raw"
    echo "5) UDP via IPVS"
    read -rp "Select [1-5]: " method
    case $method in
      2) TRANS[$proto]="iptables";;
      3) TRANS[$proto]="socat";;
      4) TRANS[$proto]="udp2raw";;
      5) TRANS[$proto]="ipvs";;
      *) TRANS[$proto]="haproxy";;
    esac
  done

  configure_ipvs() {
    local proto=$1
    local port=${PROT_PORT[$proto]}
    local fpath=/opt/utm/ipvs-${IRAN_NODE}-${proto}.sh
    mkdir -p /opt/utm
    cat > "$fpath" <<EOF
#!/bin/bash
modprobe ip_vs
modprobe ip_vs_rr
ipvsadm -C
ipvsadm -A -u 0.0.0.0:$port -s rr
EOF
    for ip in "${!HOST_IPS[@]}"; do
      echo "ipvsadm -a -u 0.0.0.0:$port -r $ip:$port -m" >> "$fpath"
    done
    chmod +x "$fpath"
    bash "$fpath"
    (crontab -l 2>/dev/null; echo "*/15 * * * * $fpath") | crontab -
    grep -q "$fpath" /etc/rc.local || echo "$fpath &" >> /etc/rc.local
  }

  configure_haproxy() {
    echo "[*] Writing HAProxy config..."
    cat > /etc/haproxy/haproxy.cfg <<EOF
global
  log /dev/log local0
  daemon
  maxconn 2048

defaults
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
EOF

    for proto in "${!ENABLED[@]}"; do
      [[ ${TRANS[$proto]} == "haproxy" ]] || continue
      port=${PROT_PORT[$proto]}
      echo -e "\nfrontend ${proto}_in\n  bind *:$port\n  default_backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
      echo "backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
      for ip in "${!HOST_IPS[@]}"; do
        echo "  server ${proto}_$ip $ip:$port check" >> /etc/haproxy/haproxy.cfg
      done
    done
    systemctl restart haproxy || true
  }

  configure_udp2raw_remote() {
    local proto=$1
    local port=${PROT_PORT[$proto]}
    local iran_ip=$(curl -s https://ipinfo.io/ip)

    for ip in "${!HOST_IPS[@]}"; do
      echo "[Foreign:$ip] Installing udp2raw for $proto:$port"
      creds="${CREDENTIALS[$ip]}"
      user=${creds%%:*}
      pass=${creds##*:}

      sshpass -p "$pass" ssh -o StrictHostKeyChecking=no $user@$ip "curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200801.0/udp2raw_amd64 -o /usr/local/bin/udp2raw && chmod +x /usr/local/bin/udp2raw"

      sshpass -p "$pass" ssh -o StrictHostKeyChecking=no $user@$ip "bash -c '
cat > /etc/systemd/system/udp2raw-$IRAN_NODE-$proto.service <<EOL
[Unit]
Description=udp2raw tunnel for $proto from $IRAN_NODE
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l0.0.0.0:$port -r $iran_ip:$port --raw-mode faketcp
Restart=always

[Install]
WantedBy=multi-user.target
EOL
systemctl daemon-reexec
systemctl enable udp2raw-$IRAN_NODE-$proto
systemctl restart udp2raw-$IRAN_NODE-$proto
'"
    done
  }

  for proto in "${!ENABLED[@]}"; do
    case ${TRANS[$proto]} in
      ipvs) configure_ipvs "$proto";;
      udp2raw) configure_udp2raw_remote "$proto";;
    esac
  done

  configure_haproxy
  echo -e "\n✅ Tunnel setup completed for $IRAN_NODE"
  for proto in "${!ENABLED[@]}"; do
    echo " - $proto on ${PROT_PORT[$proto]} via ${TRANS[$proto]}"
  done
}

function uninstall() {
  echo "[*] Uninstalling UTM..."
  systemctl stop haproxy || true
  systemctl disable haproxy || true
  ipvsadm -C || true
  rm -rf /etc/haproxy/haproxy.cfg /opt/utm
  crontab -l | grep -v "/opt/utm/" | crontab -
  echo "✅ Uninstalled successfully."
}

function show_status() {
  echo "[*] Tunnel Status (Iran server):"
  ss -tunlp | grep -E '0.0.0.0:' || echo "No active listeners."
}

menu
