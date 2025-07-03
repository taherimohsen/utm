\#!/bin/bash

# install.sh - Ultimate Tunnel Manager with full automation (final version)

set -euo pipefail

clear
echo -e "\e\[1;36mUltimate Tunnel Manager (UTM)\e\[0m - Automated Tunnel Deployment"
echo "=================================================================="

menu() {
echo ""
echo "1) Install / Configure Tunnel"
echo "2) Uninstall Tunnel (Clean)"
echo "3) Show Tunnel Status"
echo "4) Exit"
echo ""
read -rp "Select an option \[1-4]: " opt
case \$opt in
1\) setup\_tunnel;;
2\) uninstall\_tunnel;;
3\) show\_status;;
\*) exit 0;;
esac
}

setup\_tunnel() {
apt update && apt install -y ipvsadm curl dnsutils sshpass haproxy socat

read -rp "Enter unique name for this Iranian server (e.g. iran1): " IRAN\_NODE
echo "\n🌍 Enter comma-separated foreign server hostnames or IPs (e.g. ssh.example.com,185.44.1.3):"
read -rp "Foreign nodes: " FOREIGN\_HOSTS\_RAW
IFS=',' read -ra FOREIGN\_HOSTS <<< "\$FOREIGN\_HOSTS\_RAW"

declare -A HOST\_CREDENTIALS
for host in "\${FOREIGN\_HOSTS\[@]}"; do
for ip in \$(dig +short "\$host" | grep -Eo '(\[0-9]{1,3}.){3}\[0-9]+'); do
read -rp "Username for \$ip: " user
read -rsp "Password for \$ip: " pass
echo
HOST\_CREDENTIALS\[\$ip]="\$user:\$pass"
done
done

declare -A ENABLED PROT\_PORT TRANS\_METHOD
PROTOCOLS=(ssh vless vmess openvpn)
for proto in "\${PROTOCOLS\[@]}"; do
read -rp "Enable tunnel for \$proto? \[y/N]: " yn
if \[\[ "\$yn" =\~ ^\[Yy]\$ ]]; then
read -rp "Port for \$proto: " port
ENABLED\[\$proto]=1
PROT\_PORT\[\$proto]=\$port

```
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
```

done

resolve\_ips() {
local domain=\$1
dig +short "\$domain" | grep -Eo '(\[0-9]{1,3}.){3}\[0-9]+'
}

ssh\_foreign() {
local ip=\$1 cmd=\$2
local creds=\${HOST\_CREDENTIALS\[\$ip]}
local user=\${creds%%:*}
local pass=\${creds##*:}
sshpass -p "\$pass" ssh -o StrictHostKeyChecking=no "\$user"@"\$ip" "\$cmd"
}

scp\_foreign() {
local ip=\$1 localfile=\$2 remotefile=\$3
local creds=\${HOST\_CREDENTIALS\[\$ip]}
local user=\${creds%%:*}
local pass=\${creds##*:}
sshpass -p "\$pass" scp -o StrictHostKeyChecking=no "\$localfile" "\$user"@"\$ip":"\$remotefile"
}

setup\_ipvs() {
local proto=\$1
local port=\${PROT\_PORT\[\$proto]}
local file=/opt/utm/ipvs-\${IRAN\_NODE}-\${proto}.sh
echo "Configuring IPVS for \$proto (port \$port)"
mkdir -p /opt/utm
cat > "\$file" <\<EOF
\#!/bin/bash
modprobe ip\_vs
modprobe ip\_vs\_rr
ipvsadm -C
ipvsadm -A -u 0.0.0.0:\$port -s rr
EOF
for host in "\${FOREIGN\_HOSTS\[@]}"; do
for ip in \$(resolve\_ips "\$host"); do
echo "ipvsadm -a -u 0.0.0.0:\$port -r \$ip:\$port -m" >> "\$file"
done
done
chmod +x "\$file"
(crontab -l 2>/dev/null; echo "\*/30 \* \* \* \* \$file") | crontab -
grep -q "\$file" /etc/rc.local || echo "\$file &" >> /etc/rc.local
bash "\$file"
}

gen\_haproxy() {
echo "Generating HAProxy config..."
cat > /etc/haproxy/haproxy.cfg <\<EOF
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
for proto in "\${!ENABLED\[@]}"; do
\[\[ \${TRANS\_METHOD\[\$proto]} == "haproxy" ]] || continue
port=\${PROT\_PORT\[\$proto]}
echo -e "\nfrontend \${proto}\_in\n  bind \*:\$port\n  default\_backend \${proto}\_out" >> /etc/haproxy/haproxy.cfg
echo "backend \${proto}*out" >> /etc/haproxy/haproxy.cfg
for host in "\${FOREIGN\_HOSTS\[@]}"; do
for ip in \$(resolve\_ips "\$host"); do
echo "  server \${proto}*\$ip \$ip:\$port check" >> /etc/haproxy/haproxy.cfg
done
done
done
systemctl restart haproxy || true
(crontab -l 2>/dev/null; echo "0 \*/6 \* \* \* systemctl restart haproxy") | crontab -
}

setup\_udp2raw\_foreign() {
local proto=\$1
local port=\${PROT\_PORT\[\$proto]}
local local\_ip=\$(curl -s [https://ipinfo.io/ip](https://ipinfo.io/ip))
for host in "\${FOREIGN\_HOSTS\[@]}"; do
for ip in \$(resolve\_ips "\$host"); do
echo "\[Foreign] Configuring udp2raw on \$ip for \$proto..."
SERVICE="udp2raw-\${IRAN\_NODE}-\${proto}"
TMPFILE="/tmp/\$SERVICE.service"
cat > "\$TMPFILE" <\<EOL
\[Unit]
Description=UTM UDP2RAW \$proto \$IRAN\_NODE
After=network.target

\[Service]
ExecStart=/usr/local/bin/udp2raw -c -l0.0.0.0:\$port -r \$local\_ip:\$port --raw-mode faketcp
Restart=always

\[Install]
WantedBy=multi-user.target
EOL
ssh\_foreign "\$ip" "curl -L [https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200801.0/udp2raw\_amd64](https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200801.0/udp2raw_amd64) -o /usr/local/bin/udp2raw && chmod +x /usr/local/bin/udp2raw"
scp\_foreign "\$ip" "\$TMPFILE" "/etc/systemd/system/\$SERVICE.service"
ssh\_foreign "\$ip" "systemctl daemon-reexec && systemctl enable \$SERVICE && systemctl restart \$SERVICE"
done
done
}

for proto in "\${!ENABLED\[@]}"; do
case \${TRANS\_METHOD\[\$proto]} in
ipvs) setup\_ipvs "\$proto";;
udp2raw) setup\_udp2raw\_foreign "\$proto";;
haproxy) ;;  # already handled
esac
done

gen\_haproxy
echo -e "\n✅ Setup complete for \$IRAN\_NODE"
for proto in "\${!ENABLED\[@]}"; do
echo "- \$proto on port \${PROT\_PORT\[\$proto]} via \${TRANS\_METHOD\[\$proto]}"
done
}

uninstall\_tunnel() {
echo "🧹 Cleaning up..."
systemctl stop haproxy || true
systemctl disable haproxy || true
rm -f /etc/haproxy/haproxy.cfg
ipvsadm -C || true
crontab -l | grep -v "/opt/utm/" | crontab -
rm -rf /opt/utm
echo "✅ Uninstalled UTM"
}

show\_status() {
echo "🔍 Active tunnels:"
ss -tunlp | grep -Eo '0.0.0.0:(\[0-9]+)' | sort -u || echo "No active tunnels found."
}

menu
