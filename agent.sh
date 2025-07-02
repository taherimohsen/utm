#!/bin/bash
# agent.sh – Secure foreign server agent for UTM

set -euo pipefail

clear
echo "🌍 UTM Foreign Server Agent"
echo "============================="

read -p "Enter Iranian server IP or domain: " iran_ip
read -p "SSH port on Iranian server (default: 22): " ssh_port
ssh_port=${ssh_port:-22}

mkdir -p /opt/utm/logs /opt/utm/scripts

if [[ ! -f ~/.ssh/id_rsa ]]; then
  echo "🔐 No SSH key found. Generating one..."
  ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
  echo "📌 Copy the following public key to the Iran server's ~/.ssh/authorized_keys:"
  echo "========================================================"
  cat ~/.ssh/id_rsa.pub
  echo "========================================================"
  exit 0
fi

cat <<EOF > /opt/utm/scripts/foreign-agent-listen.sh
#!/bin/bash
while true; do
  echo "⏳ Checking for incoming secure instructions from Iran server..."
  ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -p $ssh_port root@${iran_ip} "cat /opt/utm/payload.sh" | bash
  sleep 10
done
EOF
chmod +x /opt/utm/scripts/foreign-agent-listen.sh

cat <<EOF > /etc/systemd/system/utm-agent.service
[Unit]
Description=UTM Foreign Agent (SSH-based secure listener)
After=network.target

[Service]
Type=simple
ExecStart=/opt/utm/scripts/foreign-agent-listen.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable utm-agent
systemctl start utm-agent

echo "✅ Secure Agent is polling Iranian server ($iran_ip) via SSH port $ssh_port."
echo "📥 To send instructions, upload a script to /opt/utm/payload.sh on the Iran server."
echo "🛠 To manage agent: systemctl [start|stop|restart] utm-agent"

exit 0
