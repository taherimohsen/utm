#!/bin/bash
# uninstall.sh - Clean removal of Ultimate Tunnel Manager
set -euo pipefail

clear
echo -e "\e[1;31mUltimate Tunnel Manager - Uninstaller\e[0m"
echo "==============================================="

read -rp "Are you sure you want to completely remove UTM? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "❌ Aborted by user."
  exit 1
fi

# Stop HAProxy and remove its config
systemctl stop haproxy || true
systemctl disable haproxy || true
rm -f /etc/haproxy/haproxy.cfg

# Flush and clear IPVS
ipvsadm -C || true

# Remove any udp2raw services
rm -f /etc/systemd/system/udp2raw-*.service || true
systemctl daemon-reexec

# Remove cron jobs related to UTM
crontab -l 2>/dev/null | grep -v '/opt/utm/' | crontab -

# Remove local UTM directory
rm -rf /opt/utm

# Clean rc.local additions
sed -i '/\/opt\/utm\//d' /etc/rc.local || true

# Uninstall optional binaries if not needed
rm -f /usr/local/bin/udp2raw_amd64 /usr/local/bin/udp2raw

# Remove all foreign config files left manually
rm -f /tmp/udp2raw-*.service || true

systemctl daemon-reload

echo -e "\n✅ UTM completely uninstalled.\n"
