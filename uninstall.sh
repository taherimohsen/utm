#!/bin/bash
# uninstall.sh – حذف کامل UTM

set -euo pipefail

echo "🧹 Uninstalling Ultimate Tunnel Manager..."

systemctl stop haproxy || true
systemctl disable haproxy || true
pkill -f udp2raw || true

for proto in SSH Vless Vmess OpenVPN; do
  systemctl stop udp2raw-${proto}.service || true
  systemctl disable udp2raw-${proto}.service || true
  rm -f /etc/systemd/system/udp2raw-${proto}.service
done

rm -f /etc/haproxy/haproxy.cfg
rm -f /etc/systemd/system/utm-agent.service
rm -f /opt/utm/scripts/foreign-agent-listen.sh
rm -rf /opt/utm

iptables -t nat -F || true
iptables -F || true
netfilter-persistent save || true

ufw --force disable

echo "✅ UTM fully removed."
exit 0
