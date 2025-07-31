##!/bin/bash

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No color

# Helper function for live output with color
run_cmd() {
    echo -e "${YELLOW}Running: $@${NC}"
    sudo $@ | tee /dev/tty
}

# Function to install Backhaul
install_backhaul() {
    echo -e "${BLUE}Creating directory and downloading Backhaul...${NC}"
    run_cmd mkdir -p /root/backhaul && cd /root/backhaul
    run_cmd wget https://github.com/Musixal/Backhaul/releases/latest/download/backhaul_linux_amd64.tar.gz
    run_cmd tar -xzvf backhaul_linux_amd64.tar.gz
    run_cmd rm backhaul_linux_amd64.tar.gz

    # Server selection
    echo -e "${GREEN}Is this an Iran server or a Kharej server?${NC}"
    select server in "Iran" "Kharej"; do
        [[ -n "$server" ]] && break
    done

    # IP version selection
    echo -e "${GREEN}Are you using IPv4 or IPv6?${NC}"
    select ip_version in "IPv4" "IPv6"; do
        ip_addr=$([[ "$ip_version" == "IPv4" ]] && echo "0.0.0.0" || echo "[::]")
        [[ -n "$ip_version" ]] && break
    done

    # Port input
    echo -e "${GREEN}Enter the port numbers (space-separated):${NC}"
    read -a ports

    # Token input
    echo -e "${GREEN}Enter the token:${NC}"
    read token

    # Nodelay input
    echo -e "${GREEN}Enable nodelay? (true/false)${NC}"
    read nodelay

    # Tunnel port input
    echo -e "${GREEN}Enter the tunnel port:${NC}"
    read tunnel_port

    config_file="/root/backhaul/config.toml"

    # Create config file for Iran server
    if [[ "$server" == "Iran" ]]; then
        cat > $config_file <<EOF
[server]
bind_addr = "$ip_addr:$tunnel_port"
transport = "tcp"
accept_udp = false
token = "$token"
keepalive_period = 75
nodelay = $nodelay
heartbeat = 40
channel_size = 2048
sniffer = false
web_port = 2060
sniffer_log = "/root/backhaul.json"
log_level = "info"
ports = [$(printf "\"%s=%s\"," "${ports[@]}" | sed 's/,$//')]
EOF
    else
        # Create config file for Kharej server
        echo -e "${GREEN}Enter the Iran IP:${NC}"
        read iran_ip
        [[ "$ip_version" == "IPv6" ]] && iran_ip="[$iran_ip]"

        echo -e "${GREEN}Enter the connection pool number:${NC}"
        read conn_pool

        cat > $config_file <<EOF
[client]
remote_addr = "$iran_ip:$tunnel_port"
transport = "tcp"
token = "$token"
connection_pool = $conn_pool
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
nodelay = $nodelay
retry_interval = 3
sniffer = false
web_port = 2060
sniffer_log = "/root/backhaul.json"
log_level = "info"
EOF
    fi

    # Set up systemd service
    echo -e "${BLUE}Setting up Backhaul service...${NC}"
    cat > /etc/systemd/system/backhaul.service <<EOF
[Unit]
Description=Backhaul Reverse Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=/root/backhaul/backhaul -c /root/backhaul/config.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable backhaul.service
    run_cmd systemctl start backhaul.service
    echo -e "${GREEN}Backhaul installed successfully!${NC}"
}

# Function to uninstall Backhaul
uninstall_backhaul() {
    echo -e "${RED}Are you sure you want to uninstall Backhaul? (y/n)${NC}"
    read confirm
    if [[ "$confirm" == "y" ]]; then
        run_cmd systemctl stop backhaul.service
        run_cmd systemctl disable backhaul.service
        run_cmd rm /etc/systemd/system/backhaul.service
        run_cmd rm -rf /root/backhaul
        echo -e "${GREEN}Backhaul uninstalled successfully.${NC}"
    else
        echo -e "${YELLOW}Uninstall canceled.${NC}"
    fi
}

# Function to update Backhaul
update_backhaul() {
    cd /root/backhaul
    run_cmd rm backhaul_linux_amd64.tar.gz
    run_cmd wget https://github.com/Musixal/Backhaul/releases/latest/download/backhaul_linux_amd64.tar.gz
    run_cmd tar -xzvf backhaul_linux_amd64.tar.gz
    run_cmd rm backhaul_linux_amd64.tar.gz
    run_cmd systemctl restart backhaul.service
    echo -e "${GREEN}Backhaul updated successfully.${NC}"
}

# Function to restart Backhaul service
restart_backhaul() {
    echo -e "${BLUE}Restarting Backhaul service...${NC}"
    run_cmd systemctl restart backhaul.service
    echo -e "${GREEN}Backhaul service restarted.${NC}"
}

# Function to set up cronjob for restarting Backhaul
setup_cron() {
    echo -e "${GREEN}How often (in hours) do you want Backhaul to restart? (Options: 1, 3, 6, 12, 24)${NC}"
    read interval
    cron_expr="0 */$interval * * * /usr/bin/systemctl restart backhaul.service"
    (crontab -l 2>/dev/null; echo "$cron_expr") | crontab -
    echo -e "${GREEN}Cron job set to restart Backhaul every $interval hours.${NC}"
}

# Main menu
while true; do
    echo -e "${BLUE}Backhaul Management Script${NC}"
    echo "1. Install Backhaul"
    echo "2. Uninstall Backhaul"
    echo "3. Update Backhaul"
    echo "4. Restart Backhaul Service"
    echo "5. Setup Cronjob to Restart Service"
    echo "6. Exit"
    echo -e "${GREEN}Select an option:${NC}"
    read choice

    case $choice in
        1) install_backhaul ;;
        2) uninstall_backhaul ;;
        3) update_backhaul ;;
        4) restart_backhaul ;;
        5) setup_cron ;;
        6) echo -e "${YELLOW}Exiting script.${NC}"; exit ;;
        *) echo -e "${RED}Invalid option. Please try again.${NC}" ;;
    esac
done
