#!/bin/bash

# Improved backhaul monitor management script
# Author: Enhanced version with better error handling and security

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
MONITOR_SCRIPT="/usr/local/bin/backhaul-monitor.sh"
LOG_FILE="/var/log/backhaul-monitor.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log_message() {
    echo -e "${2:-$GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error_exit() {
    log_message "ERROR: $1" "$RED" >&2
    exit 1
}

# Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
    error_exit "This script must be run as root."
fi

# Validate service name
validate_service() {
    local service="$1"
    if [[ ! "$service" =~ ^[a-zA-Z0-9._-]+\.service$ ]]; then
        error_exit "Invalid service name format. Must end with .service"
    fi
    
    # Use systemctl show instead of list-units
    if ! systemctl show "$service" > /dev/null 2>&1; then
        log_message "Warning: Service '$service' not found in systemctl" "$YELLOW"
        read -rp "Continue anyway? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
    fi
}

# Validate log path
validate_log_path() {
    local log_path="$1"
    local log_dir
    log_dir=$(dirname "$log_path")
    
    if [[ ! -d "$log_dir" ]]; then
        error_exit "Log directory '$log_dir' does not exist"
    fi
    
    if [[ ! -w "$log_dir" ]]; then
        error_exit "Log directory '$log_dir' is not writable"
    fi
}

# Validate time window
validate_time_window() {
    local time_window="$1"
    if ! [[ "$time_window" =~ ^[0-9]+$ ]] || [[ "$time_window" -lt 1 ]] || [[ "$time_window" -gt 60 ]]; then
        error_exit "Time window must be a number between 1 and 60 minutes"
    fi
}

# Install monitor
install_monitor() {
    log_message "Installing backhaul monitor..."
    
    # Get service name
    read -rp "Enter systemd service name to monitor (e.g. backhaul.service): " SERVICE_NAME
    [[ -z "$SERVICE_NAME" ]] && error_exit "Service name cannot be empty"
    validate_service "$SERVICE_NAME"
    
    # Get log file path
    read -rp "Enter log file path [$LOG_FILE]: " INPUT_LOG
    LOG_PATH="${INPUT_LOG:-$LOG_FILE}"
    validate_log_path "$LOG_PATH"
    
    # Get time window
    read -rp "Enter time window in minutes to check logs [5]: " TIME_WINDOW
    TIME_WINDOW="${TIME_WINDOW:-5}"
    validate_time_window "$TIME_WINDOW"
    
    # Get error regex
    read -rp "Enter error keywords (regex) to detect [error|failed|fatal]: " ERROR_REGEX
    ERROR_REGEX="${ERROR_REGEX:-error|failed|fatal}"
    
    # Test the regex
    if ! echo "test error" | grep -Eq "$ERROR_REGEX" 2>/dev/null; then
        error_exit "Invalid regex pattern"
    fi
    
    log_message "Writing monitor script to $MONITOR_SCRIPT..."
    
    # Create monitor script with better error handling
    cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
# Auto-generated backhaul monitor script
# Generated on: $(date)

set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

SERVICE="$SERVICE_NAME"
LOG="$LOG_PATH"
SINCE_MINUTES=$TIME_WINDOW
ERROR_REGEX="$ERROR_REGEX"
LOCK_FILE="/var/run/backhaul-monitor.lock"

# Prevent multiple instances
if [[ -f "\$LOCK_FILE" ]]; then
    if kill -0 "\$(cat "\$LOCK_FILE")" 2>/dev/null; then
        echo "[WARNING] \$(date '+%Y-%m-%d %H:%M:%S'): Another instance is running. Exiting." >> "\$LOG"
        exit 0
    else
        rm -f "\$LOCK_FILE"
    fi
fi

echo \$\$ > "\$LOCK_FILE"
trap 'rm -f "\$LOCK_FILE"' EXIT

# Check if service exists and is active
if ! systemctl is-enabled "\$SERVICE" >/dev/null 2>&1; then
    echo "[ERROR] \$(date '+%Y-%m-%d %H:%M:%S'): Service \$SERVICE is not enabled" >> "\$LOG"
    exit 1
fi

# Check for errors in journal
if journalctl -u "\$SERVICE" --since "\${SINCE_MINUTES} minutes ago" --no-pager -q | grep -Eiq "\$ERROR_REGEX"; then
    echo "[INFO] \$(date '+%Y-%m-%d %H:%M:%S'): Detected ERROR in \$SERVICE. Restarting service..." >> "\$LOG"
    
    # Get service status before restart
    service_status=\$(systemctl is-active "\$SERVICE" 2>/dev/null || echo "unknown")
    echo "[INFO] \$(date '+%Y-%m-%d %H:%M:%S'): Service status before restart: \$service_status" >> "\$LOG"
    
    # Restart service
    if systemctl restart "\$SERVICE"; then
        echo "[INFO] \$(date '+%Y-%m-%d %H:%M:%S'): Service \$SERVICE restarted successfully" >> "\$LOG"
    else
        echo "[ERROR] \$(date '+%Y-%m-%d %H:%M:%S'): Failed to restart service \$SERVICE" >> "\$LOG"
        exit 1
    fi
else
    echo "[DEBUG] \$(date '+%Y-%m-%d %H:%M:%S'): No errors detected in \$SERVICE" >> "\$LOG"
fi
EOF

    chmod +x "$MONITOR_SCRIPT"
    
    # Create log file with proper permissions
    touch "$LOG_PATH"
    chmod 644 "$LOG_PATH"  # More secure permissions
    chown root:root "$LOG_PATH"
    
    # Install cron job
    CRON_CMD="*/5 * * * * $MONITOR_SCRIPT"  # Fixed cron syntax
    
    if crontab -l 2>/dev/null | grep -Fq "$MONITOR_SCRIPT"; then
        log_message "Cron job already exists." "$YELLOW"
    else
        # Backup current crontab
        crontab -l 2>/dev/null > /tmp/crontab.backup || true
        
        (crontab -l 2>/dev/null; echo "# Backhaul monitor - added $(date)"; echo "SHELL=/bin/bash"; echo "PATH=/usr/bin:/bin:/usr/sbin:/sbin"; echo "$CRON_CMD") | crontab -
        log_message "Cron job installed to run every 5 minutes."
    fi
    
    # Test the monitor script
    log_message "Testing monitor script..."
    if bash -n "$MONITOR_SCRIPT"; then
        log_message "Monitor script syntax is valid."
    else
        error_exit "Monitor script has syntax errors"
    fi
    
    log_message "Installation complete!"
    log_message "Monitor will check service '$SERVICE_NAME' every 5 minutes"
    log_message "Logs will be written to: $LOG_PATH"
}

# Remove monitor
remove_monitor() {
    log_message "Removing backhaul monitor..." "$YELLOW"
    
    # Remove cron job
    if crontab -l 2>/dev/null | grep -Fq "$MONITOR_SCRIPT"; then
        # Backup current crontab
        crontab -l 2>/dev/null > /tmp/crontab.backup || true
        crontab -l 2>/dev/null | grep -Fv "$MONITOR_SCRIPT" | crontab -
        log_message "Cron job removed."
    else
        log_message "Cron job not found." "$YELLOW"
    fi
    
    # Remove monitor script
    if [[ -f "$MONITOR_SCRIPT" ]]; then
        rm -f "$MONITOR_SCRIPT"
        log_message "Monitor script removed."
    else
        log_message "Monitor script not found." "$YELLOW"
    fi
    
    # Remove lock file if exists
    rm -f /var/run/backhaul-monitor.lock
    
    log_message "Removal complete!"
}

# View/edit configuration
manage_config() {
    if [[ ! -f "$MONITOR_SCRIPT" ]]; then
        error_exit "Monitor script not found. Please install it first."
    fi
    
    echo
    log_message "Current monitor configuration:"
    echo "----------------------------------------"
    grep -E '^(SERVICE|LOG|SINCE_MINUTES|ERROR_REGEX)=' "$MONITOR_SCRIPT" | while IFS= read -r line; do
        echo "  $line"
    done
    echo "----------------------------------------"
    echo
    
    # Show cron status
    if crontab -l 2>/dev/null | grep -Fq "$MONITOR_SCRIPT"; then
        log_message "Cron job: ACTIVE"
    else
        log_message "Cron job: NOT FOUND" "$RED"
    fi
    
    # Show recent log entries
    if [[ -f "$LOG_FILE" ]]; then
        echo
        log_message "Recent log entries (last 10):"
        echo "----------------------------------------"
        tail -n 10 "$LOG_FILE" 2>/dev/null || echo "No log entries found"
        echo "----------------------------------------"
    fi
    
    echo
    read -rp "Do you want to edit configuration? [y/N]: " CONFIRM_EDIT
    if [[ "$CONFIRM_EDIT" =~ ^[Yy]$ ]]; then
        # Backup original script
        cp "$MONITOR_SCRIPT" "${MONITOR_SCRIPT}.backup"
        
        read -rp "New service name (leave blank to keep current): " NEW_SERVICE
        if [[ -n "$NEW_SERVICE" ]]; then
            validate_service "$NEW_SERVICE"
            sed -i "s|^SERVICE=.*|SERVICE=\"$NEW_SERVICE\"|" "$MONITOR_SCRIPT"
        fi
        
        read -rp "New log file path (leave blank to keep current): " NEW_LOG
        if [[ -n "$NEW_LOG" ]]; then
            validate_log_path "$NEW_LOG"
            sed -i "s|^LOG=.*|LOG=\"$NEW_LOG\"|" "$MONITOR_SCRIPT"
        fi
        
        read -rp "New time window in minutes (leave blank to keep current): " NEW_MIN
        if [[ -n "$NEW_MIN" ]]; then
            validate_time_window "$NEW_MIN"
            sed -i "s|^SINCE_MINUTES=.*|SINCE_MINUTES=$NEW_MIN|" "$MONITOR_SCRIPT"
        fi
        
        read -rp "New error regex (leave blank to keep current): " NEW_REGEX
        if [[ -n "$NEW_REGEX" ]]; then
            if echo "test error" | grep -Eq "$NEW_REGEX" 2>/dev/null; then
                sed -i "s|^ERROR_REGEX=.*|ERROR_REGEX=\"$NEW_REGEX\"|" "$MONITOR_SCRIPT"
            else
                error_exit "Invalid regex pattern"
            fi
        fi
        
        # Test updated script
        if bash -n "$MONITOR_SCRIPT"; then
            log_message "Configuration updated successfully!"
        else
            log_message "Script has syntax errors. Restoring backup..." "$RED"
            mv "${MONITOR_SCRIPT}.backup" "$MONITOR_SCRIPT"
            error_exit "Configuration update failed"
        fi
        
        rm -f "${MONITOR_SCRIPT}.backup"
    fi
}

# Main menu
show_menu() {
    echo
    echo "========================================"
    echo "    Backhaul Monitor Management"
    echo "========================================"
    echo "1) Install backhaul monitor"
    echo "2) Remove backhaul monitor"
    echo "3) View or edit monitor configuration"
    echo "4) Show monitor status"
    echo "5) Test monitor manually"
    echo "========================================"
}

# Show status
show_status() {
    echo
    log_message "Monitor Status Report:"
    echo "----------------------------------------"
    
    # Check if script exists
    if [[ -f "$MONITOR_SCRIPT" ]]; then
        echo "? Monitor script: INSTALLED"
    else
        echo "? Monitor script: NOT INSTALLED"
        return
    fi
    
    # Check cron job
    if crontab -l 2>/dev/null | grep -Fq "$MONITOR_SCRIPT"; then
        echo "? Cron job: ACTIVE"
    else
        echo "? Cron job: NOT FOUND"
    fi
    
    # Check log file
    if [[ -f "$LOG_FILE" ]]; then
        echo "? Log file: EXISTS ($(wc -l < "$LOG_FILE") lines)"
        echo "  Last modified: $(stat -c %y "$LOG_FILE")"
    else
        echo "? Log file: NOT FOUND"
    fi
    
    # Check lock file
    if [[ -f "/var/run/backhaul-monitor.lock" ]]; then
        echo "? Lock file: EXISTS (monitor may be running)"
    else
        echo "? Lock file: CLEAN"
    fi
    
    echo "----------------------------------------"
}

# Test monitor manually  
test_monitor() {
    if [[ ! -f "$MONITOR_SCRIPT" ]]; then
        error_exit "Monitor script not found. Please install it first."
    fi
    
    log_message "Testing monitor script manually..."
    echo "----------------------------------------"
    
    # Run the monitor script in debug mode
    bash -x "$MONITOR_SCRIPT"
    
    echo "----------------------------------------"
    log_message "Manual test completed. Check the log file for results."
}

# Main script
show_menu
read -rp "Enter choice [1-5]: " CHOICE

case "$CHOICE" in
    1)
        install_monitor
        ;;
    2)
        remove_monitor
        ;;
    3)
        manage_config
        ;;
    4)
        show_status
        ;;
    5)
        test_monitor
        ;;
    *)
        error_exit "Invalid choice. Please select 1-5."
        ;;
esac

echo
log_message "Operation completed successfully!"
