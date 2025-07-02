#!/bin/bash

install.sh - Ultimate Tunnel Manager with full automation

set -euo pipefail

clear
echo -e "\e[1;36mUltimate Tunnel Manager (UTM)\e[0m - Automated Tunnel Deployment"
echo "=================================================================="

install_prerequisites() {
echo "🔍 Installing prerequisites..."
apt update
apt install -y haproxy ipvsadm net-tools ufw iproute2 iptables socat curl sshpass dnsutils
modprobe ip_vs || true
modprobe ip_vs_rr || true
modprobe ip_vs_wrr || true
modprobe ip_vs_sh || true
}

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

setup_tunnel() {
install_prerequisites

read -rp "Enter unique name for this Iranian server (e.g. iran1): " IRAN_NODE
echo "\n🌍 Enter comma-separated foreign server hostnames or IPs (e.g. ssh.example.com,185.44.1.3):"
read -rp "Foreign nodes: " FOREIGN_HOSTS_RAW
IFS=',' read -ra FOREIGN_HOSTS <<< "$FOREIGN_HOSTS_RAW"

declare -A FOREIGN_CRED
for host in "${FOREIGN_HOSTS[@]}"; do
read -rp "SSH username for $host (default: root): " u
u=${u:-root}
read -rsp "Password for $host ($u): " p
echo
FOREIGN_CRED[$host]="$u:$p"
done

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
dig +short "$domain" | grep -Eo '([0-9]{1,3}.){3}[0-9]+'
}

ssh_foreign() {
local host=$1 cmd=$2
IFS=':' read -r user pass <<< "${FOREIGN_CRED[$host]}"
sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user"@"$host" "$cmd"
}

scp_foreign() {
local host=$1 localfile=$2 remotefile=$3
IFS=':' read -r user pass <<< "${FOREIGN_CRED[$host]}"
sshpass -p "$pass" scp -o StrictHostKeyChecking=no "$localfile" "$user"@"$host":"$remotefile"
}

for proto in "${!ENABLED[@]}"; do
method=${TRANS_METHOD[$proto]}
port=${PROT_PORT[$proto]}
if [[ "$method" == "ipvs" ]]; then
file="/opt/utm/ipvs-${IRAN_NODE}-${proto}.sh"
mkdir -p /opt/utm
echo "#!/bin/bash" > "$file"
echo "modprobe ip_vs" >> "$file"
echo "modprobe ip_vs_rr" >> "$file"
echo "ipvsadm -C" >> "$file"
echo "ipvsadm -A -u 0.0.0.0:$port -s rr" >> "$file"
for host in "${FOREIGN_HOSTS[@]}"; do
for ip in $(resolve_ips "$host"); do
echo "ipvsadm -a -u 0.0.0.0:$port -r $ip:$port -m" >> "$file"
done
done
chmod +x "$file"
bash "$file"
(crontab -l 2>/dev/null; echo "*/30 * * * * $file") | crontab -
elif [[ "$method" == "udp2raw" ]]; then
curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/download/20190719.0/udp2raw_binaries.tar.gz | tar -xz -C /usr/local/bin/
chmod +x /usr/local/bin/udp2raw_amd64
ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw
for host in "${FOREIGN_HOSTS[@]}"; do
ssh_foreign "$host" "apt update && apt install -y curl"
ssh_foreign "$host" "curl -L https://github.com/wangyu-/udp2raw-tunnel/releases/download/20190719.0/udp2raw_binaries.tar.gz | tar -xz -C /usr/local/bin/ && chmod +x /usr/local/bin/udp2raw_amd64 && ln -sf /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw"
done
elif [[ "$method" == "socat" ]]; then
for host in "${FOREIGN_HOSTS[@]}"; do
ssh_foreign "$host" "apt install -y socat"
done
fi
done

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

