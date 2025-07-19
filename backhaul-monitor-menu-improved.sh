#!/bin/bash
# Backhaul Monitoring Control Panel (Improved version)

CONFIG_FILE="/etc/backhaul-monitor.conf"
LOG_FILE="/var/log/backhaul-monitor.log"
MONITOR_SCRIPT="/root/backhaul-standalone-monitor.sh"
SERVICE_FILE="/etc/systemd/system/backhaul-standalone-monitor.service"

setup_monitoring() {
    echo "🔍 شناسایی فایل‌های سرویس backhaul..."
    mapfile -t services < <(find /etc/systemd/system /lib/systemd/system -type f -name 'backhaul*.service' -exec basename {} \;)

    if [[ ${#services[@]} -eq 0 ]]; then
        echo "❌ هیچ فایل سرویسی با پیشوند backhaul پیدا نشد."
        return
    fi

    echo "✅ سرویس‌های یافت‌شده:"
    for i in "${!services[@]}"; do
        echo "  [$((i+1))] ${services[$i]}"
    done

    read -p "🌐 IP سرور مقابل را وارد کنید (برای ping): " peer_ip
    if [[ -z "$peer_ip" ]]; then
        echo "❌ IP وارد نشده!"
        return
    fi

    selected_services="${services[*]}"
    echo "✅ افزودن سرویس‌ها به مانیتورینگ: $selected_services"

    echo "PEER_IP=$peer_ip" > "$CONFIG_FILE"
    echo "SERVICES=\"$selected_services\"" >> "$CONFIG_FILE"

    echo "🛠 راه‌اندازی سرویس systemd..."

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Standalone Backhaul Tunnel Monitor
After=network.target

[Service]
ExecStart=/bin/bash $MONITOR_SCRIPT
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-standalone-monitor.service
    echo "✅ مانیتورینگ فعال شد! هر ۳۰ ثانیه وضعیت سرویس‌ها و ping بررسی می‌شود."
}

check_log() {
    echo "📄 آخرین لاگ مانیتورینگ:"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 30 "$LOG_FILE"
    else
        echo "⛔ فایل لاگ پیدا نشد."
    fi
}

check_services() {
    echo "📡 وضعیت سرویس‌های backhaul:"
    systemctl list-units --type=service | grep backhaul || echo "⛔ هیچ سرویسی یافت نشد."
}

while true; do
    echo "═══════════════════════════════════════"
    echo " Backhaul Monitoring Panel"
    echo "═══════════════════════════════════════"
    echo "1) Setup Auto-Monitoring (Backhaul Services)"
    echo "2) Check Monitoring Log"
    echo "3) Check Backhaul Service Status"
    echo "0) Exit"
    echo "═══════════════════════════════════════"
    read -p "Enter your choice [0-3]: " choice
    case "$choice" in
        1) setup_monitoring ;;
        2) check_log ;;
        3) check_services ;;
        0) echo "خروج."; break ;;
        *) echo "❌ گزینه نامعتبر!" ;;
    esac
done
