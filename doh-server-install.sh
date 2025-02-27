#!/bin/bash
set -e

# Global backup directory
BACKUP_DIR="/var/backups/doh-backup"

#######################################
# Check if running as root.
#######################################
function check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root. Use sudo."
        exit 1
    fi
}

#######################################
# Verify OS is Ubuntu 22.04.
#######################################
function check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "22.04" ]; then
            echo "This script is designed for Ubuntu 22.04. Detected: $PRETTY_NAME"
            exit 1
        fi
    else
        echo "Cannot determine the operating system. Exiting."
        exit 1
    fi
}

#######################################
# Setup backup directory.
#######################################
function setup_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR" || { echo "Failed to create backup directory $BACKUP_DIR"; exit 1; }
    fi
}

#######################################
# Backup a file before modifying.
#######################################
function backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local timestamp
        timestamp=$(date +%s)
        local dest="$BACKUP_DIR$file"
        mkdir -p "$(dirname "$dest")"
        cp "$file" "${dest}.bak.${timestamp}"
        echo "Backed up $file to ${dest}.bak.${timestamp}"
    fi
}

#######################################
# Restore backup for a given file.
#######################################
function restore_backup_for_file() {
    local file="$1"
    local backup_pattern="$BACKUP_DIR$file.bak.*"
    local backup_file
    backup_file=$(ls -1 $backup_pattern 2>/dev/null | sort | tail -n 1 || true)
    if [ -n "$backup_file" ]; then
        cp "$backup_file" "$file"
        echo "Restored backup for $file from $backup_file"
    else
        rm -f "$file"
        echo "No backup found for $file. File removed."
    fi
}

#######################################
# Remove & Reinstall Necessary Packages
#######################################
function reinstall_packages() {
    echo "Checking and reinstalling necessary packages..."

    for pkg in unbound dnsdist certbot; do
        if dpkg -s $pkg &>/dev/null; then
            echo "Purging existing installation of $pkg..."
            apt purge -y $pkg
        fi
        echo "Installing $pkg..."
        apt install -y $pkg
    done
}

#######################################
# Fix Unbound Issues and Validate Configuration
#######################################
function fix_unbound() {
    echo "Checking Unbound configuration..."

    # Ensure root hints file exists
    if [ ! -f "/var/lib/unbound/root.hints" ]; then
        echo "Downloading root hints file..."
        wget -O /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
    fi

    # Ensure Unbound directories exist
    echo "Ensuring Unbound directories exist..."
    mkdir -p /var/lib/unbound /var/log/unbound

    # Fix ownership & permissions
    echo "Fixing Unbound file permissions..."
    chown -R unbound:unbound /etc/unbound /var/lib/unbound /var/log/unbound
    chmod -R 755 /etc/unbound /var/lib/unbound /var/log/unbound

    # Validate Unbound configuration before restarting
    echo "Validating Unbound configuration..."
    if ! unbound-checkconf; then
        echo "Unbound configuration has errors! Fix them and rerun the script."
        exit 1
    fi

    echo "Restarting Unbound..."
    systemctl restart unbound

    # Check service status after restart
    if ! systemctl is-active --quiet unbound; then
        echo "Unbound failed to start. Checking logs..."
        journalctl -xeu unbound --no-pager | tail -n 20
        exit 1
    fi

    echo "Unbound started successfully!"
}

#######################################
# Install Unbound and Configure it as a local DNS resolver
#######################################
function install_unbound() {
    reinstall_packages

    echo "Configuring Unbound..."
    local conf_dir="/etc/unbound/unbound.conf.d"
    mkdir -p "$conf_dir"
    local unbound_conf="$conf_dir/doh.conf"
    backup_file "$unbound_conf"
    cat << 'EOF' > "$unbound_conf"
server:
    verbosity: 1
    interface: 127.0.0.1
    interface: 0.0.0.0
    interface: ::0
    access-control: 127.0.0.1 allow
    access-control: 0.0.0.0/0 allow
    access-control: ::0/0 allow
    do-daemonize: no
    num-threads: 4
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    root-hints: "/var/lib/unbound/root.hints"
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    prefetch: yes
    cache-min-ttl: 3600
    cache-max-ttl: 86400
EOF

    fix_unbound
}

#######################################
# Rollback changes: Stop services and restore configuration files.
#######################################
function rollback() {
    echo "---------------------"
    echo "Starting rollback..."
    echo "---------------------"
    systemctl stop dnsdist || true
    systemctl stop unbound || true

    echo "Restoring Unbound configuration..."
    restore_backup_for_file "/etc/unbound/unbound.conf.d/doh.conf"

    echo "Rollback complete."
    exit 0
}

#######################################
# Main installation function.
#######################################
function main() {
    check_root
    check_os
    setup_backup_dir
    install_unbound

    echo "-----------------------------------------"
    echo "Unbound is now installed and configured!"
    echo "-----------------------------------------"
}

#######################################
# Display an interactive menu.
#######################################
function show_menu() {
    echo "---------------------------------"
    echo " DoH Server Installer Menu"
    echo "---------------------------------"
    echo "1) Install/Configure DoH Server"
    echo "2) Rollback changes made by this script"
    echo "3) Exit"
    read -rp "Select an option [1-3]: " MENU_CHOICE
    case "$MENU_CHOICE" in
        1) main ;;
        2) rollback ;;
        3) exit 0 ;;
        *) echo "Invalid option. Exiting." ; exit 1 ;;
    esac
}

# If the script is run with the argument "rollback", run rollback immediately.
if [ "$1" == "rollback" ]; then
    check_root
    setup_backup_dir
    rollback
fi

# Otherwise, show the interactive menu.
show_menu
