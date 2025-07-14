#!/bin/bash

set -e

# --- Constants ---
MY_GITHUB_URL="https://raw.githubusercontent.com/pilot-code/backhaul-monitoring/main"
IRAN_URL="http://37.32.13.161"
INSTALL_DIR="/root/backhaul"
CONFIG_FILE="$INSTALL_DIR/config.toml"
MONITOR_SCRIPT="/root/backhaul_monitor.sh"
LOGFILE="/var/log/backhaul_monitor.log"
STATUS_LOG="/var/log/backhaul_status_last.log"

# --- Color Setup ---
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

# --- Helpers ---
print_success() { echo "${GREEN}✅ $1${RESET}"; }
print_warning() { echo "${YELLOW}⚠️ $1${RESET}"; }
print_error()   { echo "${RED}❌ $1${RESET}"; }

prompt_default() {
  local prompt="$1"
  local default="$2"
  read -p "$prompt (default: $default): " input
  echo "${input:-$default}"
}

# --- Uninstall ---
uninstall_all() {
    print_warning "Uninstalling Backhaul and Monitoring..."

    systemctl stop backhaul.service backhaul-monitor.service backhaul-monitor.timer 2>/dev/null || true
    systemctl disable backhaul.service backhaul-monitor.service backhaul-monitor.timer 2>/dev/null || true

    rm -f /etc/systemd/system/backhaul.service
    rm -f /etc/systemd/system/backhaul-monitor.service
    rm -f /etc/systemd/system/backhaul-monitor.timer
    rm -rf "$INSTALL_DIR" "$MONITOR_SCRIPT" "$LOGFILE" "$STATUS_LOG"

    systemctl daemon-reexec
    systemctl daemon-reload

    print_success "Uninstallation complete."
}

# --- Download ---
download_backhaul_binary() {
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        i386|i686) ARCH="386" ;;
        *) print_error "Unsupported architecture!"; exit 1 ;;
    esac
    FILE_NAME="backhaul_${OS}_${ARCH}.tar.gz"

    echo "Downloading $FILE_NAME ..."
    if curl -L --fail -o "$FILE_NAME" "$MY_GITHUB_URL/$FILE_NAME"; then
        print_success "Downloaded from GitHub"
    elif curl -L --fail -o "$FILE_NAME" "$IRAN_URL/$FILE_NAME"; then
        print_success "Downloaded from Iran mirror"
    else
        print_error "Download failed from both sources"
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    tar -xzf "$FILE_NAME" -C "$INSTALL_DIR" && rm -f "$FILE_NAME"
    print_success "Extracted to $INSTALL_DIR"
}

# --- Install Service ---
install_service() {
    cat <<EOF | sudo tee /etc/systemd/system/backhaul.service > /dev/null
[Unit]
Description=Backhaul Reverse Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/backhaul -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    chmod 700 "$CONFIG_FILE"
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable backhaul.service
    systemctl restart backhaul.service
    print_success "Backhaul service installed and started"
}

# --- Menu ---
show_menu() {
    echo "==== BACKHAUL TOOL MENU ===="
    echo "1) Install Iran Server (Backhaul + Monitoring)"
    echo "2) Install Foreign Server (Backhaul + Monitoring)"
    echo "3) Install Only Monitoring"
    echo "4) Check Monitoring Log"
    echo "5) Check Backhaul Service Status"
    echo "6) Uninstall Backhaul + Monitoring"
    echo "0) Exit"
    echo "----------------------------"
    echo -n "Select an option: "
}


# --- Configuration Builders ---
build_server_config() {
    local transport=$1
    local token=$2
    local ports=$3
    local port=$4
    local ssl_cert=$5
    local ssl_key=$6

    if [ "$transport" = "tcp" ]; then
        cat <<EOF > "$CONFIG_FILE"
[server]
bind_addr = "0.0.0.0:$port"
transport = "tcp"
accept_udp = false
token = "$token"
keepalive_period = 75
nodelay = true
heartbeat = 40
channel_size = 2048
sniffer = true
web_port = 2060
sniffer_log = "$INSTALL_DIR/backhaul.json"
log_level = "info"
ports = [
"$ports"
]
EOF
    else
        cat <<EOF > "$CONFIG_FILE"
[server]
bind_addr = "0.0.0.0:$port"
transport = "wssmux"
token = "$token"
keepalive_period = 75
nodelay = true
heartbeat = 40
channel_size = 2048
mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
tls_cert = "$ssl_cert"
tls_key = "$ssl_key"
sniffer = true
web_port = 2060
sniffer_log = "$INSTALL_DIR/backhaul.json"
log_level = "info"
ports = [
"$ports"
]
EOF
    fi
    print_success "Server config written to $CONFIG_FILE"
}

build_client_config() {
    local transport=$1
    local token=$2
    local host=$3
    local port=$4

    if [ "$transport" = "tcp" ]; then
        cat <<EOF > "$CONFIG_FILE"
[client]
remote_addr = "$host:$port"
transport = "tcp"
token = "$token"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
nodelay = true
retry_interval = 3
sniffer = true
web_port = 2060
sniffer_log = "$INSTALL_DIR/backhaul.json"
log_level = "info"
EOF
    else
        cat <<EOF > "$CONFIG_FILE"
[client]
remote_addr = "$host:$port"
edge_ip = ""
transport = "wssmux"
token = "$token"
keepalive_period = 75
dial_timeout = 10
nodelay = true
retry_interval = 3
connection_pool = 8
aggressive_pool = false
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = true
web_port = 2060
sniffer_log = "$INSTALL_DIR/backhaul.json"
log_level = "info"
EOF
    fi
    print_success "Client config written to $CONFIG_FILE"
}

# --- Monitoring Installer ---
install_monitoring() {
    local interval
    interval=$(prompt_default "Monitoring check interval (minutes)" "2")

    echo "Is this Iran server or Foreign?"
    echo "1) Iran (localhost check)"
    echo "2) Foreign (check Iran server IP)"
    read -p "Choose (1 or 2): " loc
    if [ "$loc" = "1" ]; then
        read -p "Tunnel port: " TUNNEL_PORT
        TUNNEL_HOST="127.0.0.1"
    elif [ "$loc" = "2" ]; then
        read -p "Iran server IP: " TUNNEL_HOST
        read -p "Tunnel port: " TUNNEL_PORT
    else
        print_error "Invalid choice."
        exit 1
    fi

cat <<EOM > "$MONITOR_SCRIPT"
#!/bin/bash
LOGFILE="$LOGFILE"
SERVICENAME="backhaul.service"
TMP_LOG="/tmp/backhaul_monitor_tmp.log"
CHECKTIME=\$(date '+%Y-%m-%d %H:%M:%S')
TUNNEL_HOST="$TUNNEL_HOST"
TUNNEL_PORT="$TUNNEL_PORT"
LAST_CHECK=\$(date --date='1 minute ago' '+%Y-%m-%d %H:%M')

STATUS=\$(systemctl is-active \$SERVICENAME)
STATUS_DETAIL=\$(systemctl status \$SERVICENAME --no-pager | head -30)

if [ -f /var/run/reboot-required ]; then
  echo "\$CHECKTIME 🔁 Reboot required. Rebooting..." >> \$LOGFILE
  sleep 5
  reboot
fi

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

cat <<EOF | tee /etc/systemd/system/backhaul-monitor.service > /dev/null
[Unit]
Description=Backhaul Monitoring Service

[Service]
Type=oneshot
ExecStart=$MONITOR_SCRIPT
EOF

cat <<EOF | tee /etc/systemd/system/backhaul-monitor.timer > /dev/null
[Unit]
Description=Run Backhaul Monitoring every ${interval} minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=${interval}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now backhaul-monitor.timer

print_success "Monitoring configured for $TUNNEL_HOST:$TUNNEL_PORT every $interval min"
}


# --- Installation Functions ---
install_backhaul_server() {
    download_backhaul_binary

    echo "Select protocol:"
    select proto in "TCP" "WSS Mux"; do
        case $REPLY in
            1) TUNNEL_TYPE="tcp"; break ;;
            2) TUNNEL_TYPE="wssmux"; break ;;
            *) print_warning "Invalid selection." ;;
        esac
    done

    read -p "Backhaul token: " BKTOKEN
    read -p "Main tunnel port (e.g. 3080 or 443): " TUNNEL_PORT
    read -p "Tunneling ports (comma-separated, e.g. 80,443,2086): " PORTS_RAW
    PORTS=$(echo "$PORTS_RAW" | tr -d ' ' | sed 's/,/","/g')

    if [ "$TUNNEL_TYPE" = "wssmux" ]; then
        read -p "Do you have SSL cert & key? (y/n): " SSL_HAS
        if [[ "$SSL_HAS" =~ ^[Yy]$ ]]; then
            read -p "SSL cert path (e.g. /root/server.crt): " SSL_CERT
            read -p "SSL key path (e.g. /root/server.key): " SSL_KEY
        else
            apt-get update && apt-get install -y openssl
            openssl genpkey -algorithm RSA -out /root/server.key -pkeyopt rsa_keygen_bits:2048
            openssl req -new -key /root/server.key -out /root/server.csr
            openssl x509 -req -in /root/server.csr -signkey /root/server.key -out /root/server.crt -days 365
            SSL_CERT="/root/server.crt"
            SSL_KEY="/root/server.key"
            print_success "SSL generated: $SSL_CERT $SSL_KEY"
        fi
        build_server_config "wssmux" "$BKTOKEN" "$PORTS" "$TUNNEL_PORT" "$SSL_CERT" "$SSL_KEY"
    else
        build_server_config "tcp" "$BKTOKEN" "$PORTS" "$TUNNEL_PORT"
    fi

    install_service
    install_monitoring
}

install_backhaul_client() {
    download_backhaul_binary

    echo "Select protocol:"
    select proto in "TCP" "WSS Mux"; do
        case $REPLY in
            1) TUNNEL_TYPE="tcp"; break ;;
            2) TUNNEL_TYPE="wssmux"; break ;;
            *) print_warning "Invalid selection." ;;
        esac
    done

    read -p "Iran server IP: " IRAN_IP
    read -p "Tunnel port (e.g. 3080 or 443): " TUNNEL_PORT
    read -p "Backhaul token: " BKTOKEN

    build_client_config "$TUNNEL_TYPE" "$BKTOKEN" "$IRAN_IP" "$TUNNEL_PORT"
    install_service
    install_monitoring
}

check_monitor_log() {
    echo "---- Last 30 lines of monitoring log ----"
    if [ -f "$LOGFILE" ]; then
        tail -n 30 "$LOGFILE"
    else
        print_warning "No monitor log found!"
    fi
}

check_service_status() {
    echo "---- Backhaul systemctl status ----"
    if [ -f "$STATUS_LOG" ]; then
        cat "$STATUS_LOG"
    else
        print_warning "No cached status found!"
    fi
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
            check_monitor_log
            ;;
        5)
            check_service_status
            ;;
        6)
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
