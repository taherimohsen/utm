#!/bin/bash
# حذف کامل تنظیمات UTM

echo "🧹 Uninstalling Ultimate Tunnel Manager..."

# توقف سرویس‌ها
systemctl stop haproxy || true
pkill -f socat || true
pkill -f udp2raw || true

# حذف کانفیگ‌ها و مسیرها
rm -rf /etc/haproxy/haproxy.cfg
rm -f /etc/rsyslog.d/49-haproxy.conf
rm -rf /opt/utm

# حذف قوانین iptables
iptables -t nat -F
iptables -F
netfilter-persistent save

# غیرفعال کردن HAProxy
systemctl disable haproxy || true

# غیرفعال‌سازی UFW (در صورت تمایل)
# ufw disable

echo "✅ UTM has been fully removed."
