#!/bin/bash
set -e

################################################################################
# DoH Server Installer & Rollback for Ubuntu 22.04
#
# This script will:
#   • Verify root privileges and that the OS is Ubuntu 22.04.
#   • Create a backup folder (/var/backups/doh-backup) and back up any files
#     that it modifies.
#   • Update packages and install Unbound, DNSDist, certbot, and utilities.
#   • Configure Unbound as a local DNS resolver.
#   • Obtain a TLS certificate from Let's Encrypt (standalone mode).
#   • Configure DNSDist to expose a DoH endpoint at https://yourDomain/dns-query.
#   • Test the configuration.
#
# Additionally, an interactive menu is provided with options:
#   1) Install/Configure DoH Server
#   2) Rollback changes made by this script
#   3) Exit
#
# You can also run the script with the argument "rollback" to immediately revert
# all changes.
#
# IMPORTANT:
#   – Ensure your domain’s A record points to this server’s public IP.
#   – Ports 80 and 443 must be free during certificate issuance.
#   – If backups cannot be created, the installation will be aborted.
################################################################################

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
# Abort if the backup directory cannot be created.
#######################################
function setup_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR" || { echo "Failed to create backup directory $BACKUP_DIR"; exit 1; }
    fi
}

#######################################
# Backup a file before modifying.
# The backup is stored under $BACKUP_DIR preserving its path.
#
# Arguments:
#   $1 - Full path of the file to backup.
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
# If a backup exists in $BACKUP_DIR for the file, restore the most recent one.
# Otherwise, remove the file.
#
# Arguments:
#   $1 - Full path of the file to restore.
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
# Rollback changes: Stop services and restore configuration files.
#######################################
function rollback() {
    echo "---------------------"
    echo "Starting rollback..."
    echo "---------------------"
    systemctl stop dnsdist
    systemctl stop unbound

    echo "Restoring Unbound configuration..."
    restore_backup_for_file "/etc/unbound/unbound.conf.d/doh.conf"

    echo "Restoring DNSDist configuration..."
    restore_backup_for_file "/etc/dnsdist/dnsdist.conf"

    echo "Rollback complete."
    exit 0
}

#######################################
# Update system and install required packages.
#######################################
function update_and_install() {
    echo "Updating system packages..."
    apt update && apt upgrade -y

    echo "Installing required packages (unbound, dnsdist, certbot, dnsutils, curl)..."
    apt install -y unbound dnsdist certbot dnsutils curl
}

#######################################
# Configure Unbound as a local DNS resolver.
#######################################
function configure_unbound() {
    echo "Configuring Unbound as local DNS resolver..."
    local conf_dir="/etc/unbound/unbound.conf.d"
    mkdir -p "$conf_dir"
    local unbound_conf="$conf_dir/doh.conf"
    backup_file "$unbound_conf"
    cat << 'EOF' > "$unbound_conf"
server:
    verbosity: 1
    # Listen on localhost and all interfaces
    interface: 127.0.0.1
    interface: 0.0.0.0
    interface: ::0
    # Allow queries from anywhere
    access-control: 127.0.0.1 allow
    access-control: 0.0.0.0/0 allow
    access-control: ::0/0 allow
    do-daemonize: no
    num-threads: 4
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    # Root hints file location (ensure it exists or update as needed)
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

    echo "Restarting and enabling Unbound..."
    systemctl restart unbound
    systemctl enable unbound
}

#######################################
# Obtain TLS certificate using certbot (standalone mode).
#######################################
function obtain_tls_certificate() {
    echo "-----------------------------------------"
    echo "TLS Certificate Obtaining via Let's Encrypt"
    echo "-----------------------------------------"
    read -rp "Enter your domain name (e.g., example.com): " DOMAIN
    read -rp "Enter your email address (for Let's Encrypt notifications): " EMAIL

    echo ""
    echo "IMPORTANT: Make sure that $DOMAIN points to this server's public IP."
    read -n1 -r -p "Press any key to continue when ready..."

    echo ""
    echo "Stopping any service that may be using port 80/443..."
    systemctl stop dnsdist || true

    echo "Requesting certificate for $DOMAIN..."
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

    if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        echo "Certificate issuance failed. Please check your DNS and try again."
        exit 1
    fi
}

#######################################
# Configure DNSDist to serve DoH.
#######################################
function configure_dnsdist() {
    echo "Configuring DNSDist for DoH..."
    local dnsdist_conf="/etc/dnsdist/dnsdist.conf"
    backup_file "$dnsdist_conf"
    cat <<EOF > "$dnsdist_conf"
-- Forward DNS queries from DNSDist to Unbound
newServer({address="127.0.0.1:53", pool="dns"})

-- Listen on port 443 with TLS for DoH requests
setLocal("0.0.0.0:443", { doTLS=true,
                           cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
                           key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem" })

-- Expose the DoH endpoint at /dns-query
addDOHLocal("0.0.0.0:443", "/dns-query", { tls=true,
                                             cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
                                             key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem" })
EOF

    echo "Restarting and enabling DNSDist..."
    systemctl restart dnsdist
    systemctl enable dnsdist
}

#######################################
# Run tests to verify Unbound and the DoH endpoint.
#######################################
function test_setup() {
    echo "-----------------------------------------"
    echo "Testing Unbound and DoH endpoint"
    echo "-----------------------------------------"
    echo "Testing Unbound (local resolver) with dig:"
    dig @127.0.0.1 google.com

    echo ""
    echo "Testing DoH endpoint using curl:"
    echo "Query: https://${DOMAIN}/dns-query?name=google.com&type=A"
    curl -H 'accept: application/dns-json' "https://${DOMAIN}/dns-query?name=google.com&type=A"
    echo ""
}

#######################################
# Main installation function.
#######################################
function main() {
    check_root
    check_os
    setup_backup_dir
    update_and_install
    configure_unbound
    obtain_tls_certificate
    configure_dnsdist
    test_setup

    echo "-----------------------------------------"
    echo "Setup Complete!"
    echo "Your DoH server is now running at:"
    echo "    https://${DOMAIN}/dns-query"
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
