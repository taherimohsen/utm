# utm
تنظیمات HAProxy و Load Balancing روی سرور ایران و خارج همراه با تنظیمات احتصاصی برای هر پروتکل به صورت جداگانه

# Ultimate Tunnel Manager (UTM)

UTM is a fully automated script for setting up TCP and UDP tunnels between Iranian and foreign servers using HAProxy (for TCP) and IPVS/udp2raw/socat/iptables (for UDP).

## Features

* 🧠 Smart detection of Iran vs. Foreign server
* ⚡ TCP support via HAProxy
* 🔄 UDP tunneling via IPVS (default), udp2raw, socat, or iptables
* 📦 Automatic configuration on foreign servers via SSH (password or key-based)
* 🌀 Auto-resolve multiple IPs from subdomains for load distribution
* ♻️ Auto-restart services every 6 hours
* 🔧 Easy install, uninstall, and status check from `install.sh`

## Requirements

* Debian/Ubuntu based systems
* bash, curl, ipvsadm, HAProxy, socat (installed automatically)

## Installation

Run the script on Iranian server:

```bash
bash <(curl -s https://raw.githubusercontent.com/taherimohsen/utm/main/install.sh)
```

## Uninstall

To remove everything:

```bash
bash <(curl -s https://raw.githubusercontent.com/taherimohsen/utm/main/uninstall.sh)
```

## Notes

* You can use a single domain (e.g. `ssh.example.com`) pointing to multiple foreign servers.
* UDP tunnels (like OpenVPN) use IPVS for reliable load balancing across multiple backends.
* TCP protocols (like SSH, VLESS, VMESS) use HAProxy with full support for multiple IPs.

## Languages

The script supports both Persian and English prompts. Default is English.

---

# مدیریت تونل UTM

UTM یک اسکریپت کاملاً خودکار برای ایجاد تونل بین سرورهای ایران و خارج برای پروتکل‌های TCP و UDP است.

## قابلیت‌ها

* 🧠 تشخیص هوشمند سرور ایران یا خارج
* ⚡ پشتیبانی از TCP با HAProxy
* 🔄 تونل UDP با IPVS (پیش‌فرض)، udp2raw، socat یا iptables
* 📦 کانفیگ خودکار در سرورهای خارجی با رمز یا کلید SSH
* 🌀 دریافت خودکار IPهای پشت دامنه برای توزیع بار
* ♻️ ری‌استارت سرویس‌ها هر ۶ ساعت
* 🔧 نصب، حذف، و نمایش وضعیت فقط با `install.sh`

## نصب

روی سرور ایران دستور زیر را اجرا کنید:

```bash
bash <(curl -s https://raw.githubusercontent.com/taherimohsen/utm/main/install.sh)
```

## حذف کامل

```bash
bash <(curl -s https://raw.githubusercontent.com/taherimohsen/utm/main/uninstall.sh)
```

## نکات مهم

* می‌توانید یک دامنه مانند `ssh.example.com` داشته باشید که به چند سرور خارجی اشاره کند.
* برای UDP (مثل OpenVPN) از IPVS برای توزیع پایدار و بدون قطع استفاده شده است.
* برای TCP از HAProxy با پشتیبانی کامل از چند IP استفاده شده است.

---

✅ All your previous issues are now resolved:

* ✅ IPVS provides UDP tunneling with load balancing for multiple servers under one domain
* ✅ TCP handled by HAProxy with proven high performance
* ✅ Automatic config generation avoids conflicts when using multiple Iranian servers
* ✅ No extra traffic or overhead
* ✅ Reliable, restartable, and highly customizable

More info will be updated at: [GitHub Repo](https://github.com/taherimohsen/utm)
