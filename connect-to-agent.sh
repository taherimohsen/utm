#!/bin/bash
# connect-to-agent.sh – ارسال تنظیمات به agent خارجی از سرور ایران

set -euo pipefail

read -p "Enter foreign server IP/domain: " foreign_ip
read -p "SSH port for foreign server (default: 22): " foreign_ssh_port
foreign_ssh_port=${foreign_ssh_port:-22}
read -p "Path to private SSH key (default ~/.ssh/id_rsa): " ssh_key_path
ssh_key_path=${ssh_key_path:-~/.ssh/id_rsa}

read -p "Path to local payload script: " payload_path
if [[ ! -f "$payload_path" ]]; then
  echo "❌ Payload script not found at $payload_path"
  exit 1
fi

echo "🔐 Sending payload to foreign server $foreign_ip..."

scp -P $foreign_ssh_port -i $ssh_key_path "$payload_path" root@$foreign_ip:/opt/utm/payload.sh
ssh -i $ssh_key_path -p $foreign_ssh_port root@$foreign_ip "chmod +x /opt/utm/payload.sh"

echo "✅ Payload uploaded and permission set."
echo "Agent will execute payload within 10 seconds (on next poll cycle)."

exit 0
