
#!/bin/bash

# Original backhaul2.sh script content remains unchanged, just added monitoring functions.

# --- Constants ---
INSTALL_DIR="/root/backhaul"
SERVICE_DIR="/etc/systemd/system"
LOGFILE="/var/log/backhaul_monitor.log"
STATUS_LOG="/var/log/backhaul_status_last.log"
MONITOR_SCRIPT_BASE="/root/backhaul_monitor_"
BACKHAUL_SERVICE_NAME="backhaul.service"

# --- Color Setup ---
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

# --- Helper Functions ---
print_success() { echo "${GREEN}✅ $1${RESET}"; }
print_warning() { echo "${YELLOW}⚠️ $1${RESET}"; }
print_error()   { echo "${RED}❌ $1${RESET}"; }

# --- Monitoring Tools ---
monitoring_tools_menu() {
    clear
    echo -e "\e[36m==== Monitoring Tools Menu ====\e[0m"
    echo "1) Install Monitoring for a Service"
    echo "2) View Monitoring Log"
    echo "3) View Service Status"
    echo "4) Remove All Monitoring Services"
    echo "0) Back to Main Menu"
    echo -n "Select an option: "
    read choice

    case "$choice" in
        1)
            install_monitoring_for_service
            ;;
        2)
            view_monitoring_log
            ;;
        3)
            view_service_status_interactive
            ;;
        4)
            remove_monitoring_services
            ;;
        0)
            return
            ;;
        *)
            print_warning "Invalid option."
            sleep 1
            monitoring_tools_menu
            ;;
    esac
}

install_monitoring_for_service() {
    echo -e "\nAvailable Backhaul Services:"
    services=$(find "$SERVICE_DIR" -name "backhaul-*.service" | xargs -n1 basename)
    select selected_service in $services; do
        if [[ -n "$selected_service" ]]; then
            break
        else
            echo "Invalid selection. Try again."
        fi
    done

    echo -n "Enter check interval in minutes (default 2): "
    read interval
    interval=${interval:-2}

    echo -n "Enter tunnel IP or host (e.g. 127.0.0.1 or Iran server IP): "
    read tunnel_host
    echo -n "Enter tunnel port (e.g. 443): "
    read tunnel_port

    MONITOR_SCRIPT="${MONITOR_SCRIPT_BASE}${selected_service}.sh"

    cat <<EOM > "$MONITOR_SCRIPT"
#!/bin/bash
LOGFILE="$LOGFILE"
SERVICENAME="$selected_service"
TMP_LOG="/tmp/backhaul_monitor_tmp.log"
CHECKTIME=\$(date '+%Y-%m-%d %H:%M:%S')
TUNNEL_HOST="$tunnel_host"
TUNNEL_PORT="$tunnel_port"
LAST_CHECK=\$(date --date='1 minute ago' '+%Y-%m-%d %H:%M')

STATUS=\$(systemctl is-active \$SERVICENAME)
STATUS_DETAIL=\$(systemctl status \$SERVICENAME --no-pager | head -30)

PING_OK=false
ping -c1 -W1 \$TUNNEL_HOST >/dev/null && PING_OK=true

journalctl -u \$SERVICENAME --since "\$LAST_CHECK:00" | grep -E "(control channel has been closed|shutting down|channel dialer|inactive|dead)" > \$TMP_LOG

if [ "\$STATUS" != "active" ]; then
  echo "\$CHECKTIME ❌ \$SERVICENAME is DOWN! Restarting..." >> \$LOGFILE
  systemctl restart \$SERVICENAME
elif [ "\$PING_OK" = true ]; then
  if [ -s \$TMP_LOG ]; then
    echo "\$CHECKTIME ⚠️ Log error after ping OK" >> \$LOGFILE
    cat \$TMP_LOG >> \$LOGFILE
    echo "\$CHECKTIME ❗ Restarting service..." >> \$LOGFILE
    systemctl restart \$SERVICENAME
  else
    echo "\$CHECKTIME ✅ Ping OK, service healthy" >> \$LOGFILE
  fi
else
  echo "\$CHECKTIME ❌ Ping failed to \$TUNNEL_HOST. Restarting..." >> \$LOGFILE
  systemctl restart \$SERVICENAME
fi

echo "---- [ \$CHECKTIME : systemctl status \$SERVICENAME ] ----" > "$STATUS_LOG"
echo "\$STATUS_DETAIL" >> "$STATUS_LOG"
rm -f \$TMP_LOG
tail -n 50 "\$LOGFILE" > "\$LOGFILE.tmp" && mv "\$LOGFILE.tmp" "\$LOGFILE"
tail -n 35 "$STATUS_LOG" > "$STATUS_LOG.tmp" && mv "$STATUS_LOG.tmp" "$STATUS_LOG"
EOM

    chmod +x "$MONITOR_SCRIPT"

    cat <<EOF > "$SERVICE_DIR/backhaul-monitor-${selected_service}.service"
[Unit]
Description=Monitoring for $selected_service

[Service]
Type=oneshot
ExecStart=$MONITOR_SCRIPT
EOF

    cat <<EOF > "$SERVICE_DIR/backhaul-monitor-${selected_service}.timer"
[Unit]
Description=Monitor $selected_service every ${interval} min

[Timer]
OnBootSec=1min
OnUnitActiveSec=${interval}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-monitor-${selected_service}.timer

    print_success "✅ Monitoring setup complete for $selected_service"
    sleep 2
}

view_monitoring_log() {
    echo -e "\nLast 30 lines of Monitoring Log:"
    tail -n 30 "$LOGFILE"
    echo
    read -p "Press enter to return..."
}

view_service_status_interactive() {
    echo -e "\nSelect a service to view status:"
    services=$(find "$SERVICE_DIR" -name "backhaul-*.service" | xargs -n1 basename)
    select selected_service in $services; do
        if [[ -n "$selected_service" ]]; then
            systemctl status "$selected_service"
            break
        else
            echo "Invalid selection. Try again."
        fi
    done
    echo
    read -p "Press enter to return..."
}

remove_monitoring_services() {
    echo -e "\n🧹 Finding and removing all backhaul monitoring services and timers..."
    MON_SERVICES=$(find "$SERVICE_DIR" -name "backhaul-monitor-*.service" | xargs -n1 basename)

    if [ -z "$MON_SERVICES" ]; then
        echo "⚠️  No monitoring services found."
        sleep 2
        return
    fi

    for svc in $MON_SERVICES; do
        timer="${svc%.service}.timer"
        echo "Disabling and removing: $svc and $timer"
        systemctl disable --now "$timer" 2>/dev/null
        systemctl disable --now "$svc" 2>/dev/null
        rm -f "$SERVICE_DIR/$svc" "$SERVICE_DIR/$timer"
    done

    echo "Removing monitor scripts..."
    rm -f ${MONITOR_SCRIPT_BASE}*.sh

    echo "Cleaning logs..."
    rm -f "$LOGFILE" "$STATUS_LOG"

    systemctl daemon-reload
    print_success "✅ All backhaul monitoring services removed."
    sleep 2
}

# --- Main Menu ---
show_menu() {
    echo "==== BACKHAUL TOOL MENU ===="
    echo "1) Install Iran Server (Backhaul + Monitoring)"
    echo "2) Install Foreign Server (Backhaul + Monitoring)"
    echo "3) Install Only Monitoring"
    echo "4) Remove All Monitoring Services"
    echo "5) Check Monitoring Log"
    echo "6) Check Backhaul Service Status"
    echo "7) Uninstall Backhaul + Monitoring"
    echo "0) Exit"
    echo "----------------------------"
    echo -n "Select an option: "
}

# --- Main Loop ---
while true; do
    show_menu
    read -r opt
    case "$opt" in
        1)
            install_backhaul_server
            ;;
        2)
            install_backhaul_client
            ;;
        3)
            install_monitoring
            ;;
        4)
            remove_monitoring_services
            ;;
        5)
            view_monitoring_log
            ;;
        6)
            view_service_status_interactive
            ;;
        7)
            uninstall_all
            ;;
        0)
            echo "Bye!"
            exit 0
            ;;
        *)
            print_warning "Invalid option." ;;
    esac
done
