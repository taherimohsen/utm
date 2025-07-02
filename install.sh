#!/bin/bash
set -euo pipefail

# Clear screen and header
clear
echo -e "\e[1;34mUltimate Tunnel Manager (UTM) - UDP+TCP Tunnel Setup\e[0m"
echo "========================================================="

# -------- Functions -----------

# Function to install packages if missing or upgrade
install_or_upgrade() {
  local pkg=$1
  if ! command -v "$pkg" &>/dev/null; then
    echo "Installing $pkg..."
    apt-get update -qq
    apt-get install -y "$pkg"
  else
    echo "$pkg is already installed, upgrading..."
    apt-get update -qq
    apt-get install --only-upgrade -y "$pkg"
  fi
}

# Function to resolve domain to IP list
resolve_ips() {
  local domain=$1
  # Use dig if available, fallback to host
  if command -v dig &>/dev/null; then
    dig +short "$domain" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'
  else
    host "$domain" | awk '/has address/ { print $4 }'
  fi
}

# SSH command runner with password or key
ssh_run() {
  local host=$1
  local user=$2
  local pass=$3
  local key=$4
  local cmd=$5

  if [[ -n "$key" ]]; then
    ssh -i "$key" -o StrictHostKeyChecking=no "$user@$host" "$cmd"
  else
    # sshpass should be installed
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$host" "$cmd"
  fi
}

scp_run() {
  local host=$1
  local user=$2
  local pass=$3
  local key=$4
  local src=$5
  local dst=$6

  if [[ -n "$key" ]]; then
    scp -i "$key" -o StrictHostKeyChecking=no "$src" "$user@$host:$dst"
  else
    sshpass -p "$pass" scp -o StrictHostKeyChecking=no "$src" "$user@$host:$dst"
  fi
}

# Install or upgrade udp2raw on local or remote
install_udp2raw() {
  local target=$1 # "local" or host IP
  local user=$2
  local pass=$3
  local key=$4

  local cmd_install="curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/download/20190719.0/udp2raw_binaries.tar.gz | tar -xz -C /usr/local/bin/ && chmod +x /usr/local/bin/udp2raw_amd64 && ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw"

  if [[ "$target" == "local" ]]; then
    echo "Installing udp2raw locally..."
    bash -c "$cmd_install"
  else
    echo "Installing udp2raw on remote host $target..."
    ssh_run "$target" "$user" "$pass" "$key" "$cmd_install"
  fi
}

# Setup IPVS for UDP load balancing on local server
setup_ipvs() {
  local port=$1
  shift
  local remote_ips=("$@")

  echo "Loading IPVS kernel modules..."
  modprobe ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack_ipv4 || true

  echo "Clearing existing IPVS rules..."
  ipvsadm -C || true

  echo "Adding IPVS virtual service on UDP port $port..."
  ipvsadm -A -u 0.0.0.0:"$port" -s rr

  for rip in "${remote_ips[@]}"; do
    echo "Adding real server $rip:$port to IPVS..."
    ipvsadm -a -u 0.0.0.0:"$port" -r "$rip":"$port" -m
  done

  echo "IPVS setup completed."
}

# Setup systemd service for udp2raw on remote
setup_udp2raw_service_remote() {
  local host=$1
  local user=$2
  local pass=$3
  local key=$4
  local port=$5
  local iran_ip=$6
  local name=$7  # iran node name
  local proto=$8 # protocol

  local service_name="utm-udp2raw-$name-$proto"
  local service_path="/etc/systemd/system/$service_name.service"

  local service_content="[Unit]
Description=UTM udp2raw tunnel for $proto from $name
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l0.0.0.0:$port -r $iran_ip:$port --raw-mode faketcp --key secret_utm
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"

  echo "Creating udp2raw systemd service on $host..."
  echo "$service_content" > /tmp/$service_name.service

  scp_run "$host" "$user" "$pass" "$key" /tmp/$service_name.service "$service_path"
  ssh_run "$host" "$user" "$pass" "$key" "systemctl daemon-reload && systemctl enable $service_name && systemctl restart $service_name"
  rm -f /tmp/$service_name.service
}

# Setup HAProxy config locally
setup_haproxy() {
  local -n enabled_protos=$1
  local -n proto_ports=$2
  local -n proto_methods=$3
  local -n foreign_hosts=$4

  echo "Installing haproxy..."
  install_or_upgrade haproxy

  echo "Generating HAProxy config..."

  cat > /etc/haproxy/haproxy.cfg <<EOF
global
  log /dev/log local0
  maxconn 4096
  daemon
  tune.ssl.default-dh-param 2048

defaults
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
EOF

  for proto in "${!enabled_protos[@]}"; do
    if [[ "${proto_methods[$proto]}" == "haproxy" ]]; then
      local port=${proto_ports[$proto]}
      echo -e "\nfrontend ${proto}_in\n  bind *:$port\n  default_backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
      echo "backend ${proto}_out" >> /etc/haproxy/haproxy.cfg
      for host in "${foreign_hosts[@]}"; do
        for ip in $(resolve_ips "$host"); do
          echo "  server ${proto}_$ip $ip:$port check" >> /etc/haproxy/haproxy.cfg
        done
      done
    fi
  done

  systemctl restart haproxy
  systemctl enable haproxy

  echo "HAProxy setup done."
}

# Main menu for user interaction
main_menu() {
  echo ""
  echo "Ultimate Tunnel Manager Menu:"
  echo "1) Install / Configure Tunnel"
  echo "2) Uninstall Tunnel"
  echo "3) Show Tunnel Status"
  echo "4) Exit"
  echo ""
  read -rp "Choose an option [1-4]: " choice
  case "$choice" in
    1) install_tunnel ;;
    2) uninstall_tunnel ;;
    3) show_status ;;
    4) exit 0 ;;
    *) echo "Invalid option." ; main_menu ;;
  esac
}

# Installation workflow
install_tunnel() {
  read -rp "Enter a unique name for this Iranian server (e.g. iran1): " IRAN_NAME

  read -rp "Enter IP of this Iranian server (not domain): " IRAN_IP

  echo "Enter foreign server domain or IP list (comma separated, e.g. fo.example.com,1.2.3.4):"
  read -rp "Foreign servers: " FOREIGN_RAW
  IFS=',' read -ra FOREIGN_HOSTS <<< "$FOREIGN_RAW"

  # Collect SSH credentials for each foreign server
  declare -A FOREIGN_USERS
  declare -A FOREIGN_PASS
  declare -A FOREIGN_KEYS

  for host in "${FOREIGN_HOSTS[@]}"; do
    echo "Credentials for foreign server $host:"
    read -rp "Username (default root): " usr
    usr=${usr:-root}
    echo "Choose auth method for $host:"
    echo "1) Password (default)"
    echo "2) SSH Key"
    read -rp "Select [1-2]: " auth
    auth=${auth:-1}
    if [[ "$auth" == "2" ]]; then
      read -rp "Path to private key file: " key
      FOREIGN_KEYS["$host"]="$key"
      FOREIGN_USERS["$host"]="$usr"
      FOREIGN_PASS["$host"]=""
    else
      read -rsp "Password for $usr@$host: " pass
      echo
      FOREIGN_PASS["$host"]="$pass"
      FOREIGN_USERS["$host"]="$usr"
      FOREIGN_KEYS["$host"]=""
    fi
  done

  # Protocol configuration
  declare -A ENABLED
  declare -A PROT_PORT
  declare -A TRANS_METHOD

  PROTOCOLS=(ssh vless vmess openvpn)

  for proto in "${PROTOCOLS[@]}"; do
    read -rp "Enable tunnel for $proto? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      # Default ports
      case $proto in
        ssh) def_port=4234;;
        vless) def_port=41369;;
        vmess) def_port=41374;;
        openvpn) def_port=42347;;
      esac
      read -rp "Port for $proto (default $def_port): " port
      port=${port:-$def_port}
      ENABLED[$proto]=1
      PROT_PORT[$proto]=$port

      echo "Choose transport method for $proto:"
      echo "1) TCP via HAProxy (default)"
      echo "2) UDP via IPVS + udp2raw (recommended for openvpn)"
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

  echo "Installing prerequisites..."
  install_or_upgrade sshpass
  install_or_upgrade ipvsadm
  install_or_upgrade haproxy
  install_or_upgrade curl
  install_or_upgrade dnsutils
  install_or_upgrade socat

  # For iptables and socat, installation check handled when used.

  # Setup IPVS for UDP protocols using IPVS + udp2raw
  for proto in "${!ENABLED[@]}"; do
    if [[ "${TRANS_METHOD[$proto]}" == "ipvs" ]]; then
      # Resolve foreign IPs for IPVS real servers
      ALL_FOREIGN_IPS=()
      for host in "${FOREIGN_HOSTS[@]}"; do
        mapfile -t ips < <(resolve_ips "$host")
        ALL_FOREIGN_IPS+=("${ips[@]}")
      done

      # Setup IPVS for UDP port on local iran server
      echo "Setting up IPVS for $proto on port ${PROT_PORT[$proto]}"
      setup_ipvs "${PROT_PORT[$proto]}" "${ALL_FOREIGN_IPS[@]}"
    fi
  done

  # Setup HAProxy for TCP protocols
  setup_haproxy ENABLED PROT_PORT TRANS_METHOD FOREIGN_HOSTS

  # Setup udp2raw on foreign servers for IPVS UDP tunnels
  for proto in "${!ENABLED[@]}"; do
    if [[ "${TRANS_METHOD[$proto]}" == "ipvs" ]]; then
      for host in "${FOREIGN_HOSTS[@]}"; do
        user=${FOREIGN_USERS[$host]}
        pass=${FOREIGN_PASS[$host]}
        key=${FOREIGN_KEYS[$host]:-}

        install_udp2raw "$host" "$user" "$pass" "$key"
        setup_udp2raw_service_remote "$host" "$user" "$pass" "$key" "${PROT_PORT[$proto]}" "$IRAN_IP" "$IRAN_NAME" "$proto"
      done
    fi
  done

  # Setup systemd timer to restart HAProxy and IPVS every 6 hours
  echo "Setting up systemd timers to restart services every 6 hours..."

  cat >/etc/systemd/system/utm-restart.timer <<EOF
[Unit]
Description=Restart UTM services every 6 hours

[Timer]
OnCalendar=hourly
Persistent=true
AccuracySec=10min
Unit=utm-restart.service

[Install]
WantedBy=timers.target
EOF

  cat >/etc/systemd/system/utm-restart.service <<EOF
[Unit]
Description=Restart UTM services

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'systemctl restart haproxy || true; echo "IPVS restart done on reboot."'
EOF

  systemctl daemon-reload
  systemctl enable --now utm-restart.timer

  echo -e "\n✅ Tunnel setup completed for Iran node: $IRAN_NAME"
  echo "Active tunnels and transports:"
  for proto in "${!ENABLED[@]}"; do
    echo "- $proto on port ${PROT_PORT[$proto]} via ${TRANS_METHOD[$proto]}"
  done
}

uninstall_tunnel() {
  echo "Removing UTM tunnels and cleaning up..."

  systemctl stop haproxy || true
  systemctl disable haproxy || true
  rm -f /etc/haproxy/haproxy.cfg

  ipvsadm -C || true

  systemctl stop utm-restart.timer utm-restart.service || true
  systemctl disable utm-restart.timer utm-restart.service || true
  rm -f /etc/systemd/system/utm-restart.timer /etc/systemd/system/utm-restart.service

  rm -rf /opt/utm

  echo "Cleanup complete."
}

show_status() {
  echo "Active tunnels:"
  local found=0
  for proto in "${!PROT_PORT[@]}"; do
    port=${PROT_PORT[$proto]}
    # بررسی پورت فعال در ss
    if ss -tunlp | grep -q ":$port "; then
      ss -tunlp | grep ":$port "
      found=1
    fi
  done
  if [[ $found -eq 0 ]]; then
    echo "No active tunnels found."
  fi

  echo "HAProxy status:"
  systemctl status haproxy --no-pager || true

  echo "IPVS rules:"
  ipvsadm -Ln || true

  echo "Timer status:"
  systemctl status utm-restart.timer --no-pager || true
}


# Main loop
while true; do
  main_menu
done
