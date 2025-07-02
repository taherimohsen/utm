# utm
تنظیمات HAProxy و Load Balancing روی سرور ایران و خارج همراه با تنظیمات احتصاصی برای هر پروتکل به صورت جداگانه

# Ultimate Tunnel Manager (UTM)

## معرفی
این پروژه برای مدیریت خودکار تونل‌های چندپروتکلی بین سرورهای ایران و خارج طراحی شده است.  
پشتیبانی کامل از TCP و UDP (با udp2raw برای UDP) به همراه سیستم agent امن و خودکار.

---

## محتویات

- `install.sh` : نصب کامل، شامل نصب پیش‌نیاز، کانفیگ HAProxy، تنظیم فایروال و تونل UDP
- `uninstall.sh` : حذف کامل پروژه و پاکسازی سیستم
- `agent.sh` : اسکریپت Agent برای سرور خارجی جهت دریافت دستورات امن از سرور ایران (SSH-based)
- `connect-to-agent.sh` : ارسال تنظیمات/دستورات به Agent سرور خارجی
- `/opt/utm/payload.sh` : اسکریپت دستورات که توسط Agent اجرا می‌شود (ایجاد و آپلود توسط کاربر)

---

## نصب

1. روی هر دو سرور ایران و خارج، `install.sh` را اجرا کنید:

```bash
bash install.sh


# UTM – Ultimate Tunnel Manager

**UTM** is a complete and automated tunnel manager that configures TCP and UDP tunnels between an Iranian and a foreign server, supporting multiple protocols including SSH, V2Ray (Vless/Vmess), and OpenVPN.

## 🔧 Features

- Auto-detection of local/foreign server
- Independent configuration of each protocol
- Separate local and remote ports
- Supports TCP via HAProxy
- Supports UDP via iptables, socat, or udp2raw
- Fully automated installation and setup
- Built-in Uninstaller (`uninstall.sh`)
- Automatic firewall configuration
- Logging for each protocol

## 📦 Installation

On both **Iran** and **Foreign** servers:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/taherimohsen/utm/main/install.sh)
```

The script will ask you to:
- Specify protocol (SSH, Vless, etc)
- Enter local and remote ports
- Choose TCP or UDP
- Select UDP transport method (iptables/socat/udp2raw)

## 🧰 Agent Support (for foreign server)

The foreign server can act as an **agent** to receive tunnel settings from the Iranian server (not implemented in full yet).

## 📂 File Structure

- `install.sh`: main installer and configurator
- `uninstall.sh`: clean removal script
- `/opt/utm/logs`: log directory for socat and udp2raw

## 🚫 Uninstallation
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/taherimohsen/utm/main/uninstall.sh)
```

## 🛠 Requirements
- Ubuntu/Debian based server
- Internet access during installation
- Root access (sudo)

## 🔐 Notes
- UDP uses raw tunneling for full NAT traversal (udp2raw)
- TCP tunneled cleanly via HAProxy (up to 10k concurrent connections)

---

Made with 💻 by [@taherimohsen](https://github.com/taherimohsen)

Feel free to fork and contribute.
