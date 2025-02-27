#!/bin/bash
set -e

################################################################################
# DoH Server Installer for Ubuntu 22.04
#
# This script will:
#   • Check for root privileges and that the OS is Ubuntu 22.04.
#   • Update system packages.
#   • Install Unbound, DNSDist, certbot, and supporting utilities.
#   • Configure Unbound as a local DNS resolver.
#   • Obtain a TLS certificate from Let's Encrypt (standalone mode).
#   • Configure DNSDist to expose a DoH endpoint at https://yourDomain/dns-query.
#   • Restart and enable services, then test the configuration.
#
# IMPORTANT:
#   – Ensure your domain’s A record points to this server’s public IP.
#   – Ports 80 and 443 must be free during certificate issuance.
################################################################################

# Check if running as root.
function check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root. Use sudo."
        exit 1
    fi
}

# Verify OS is Ubuntu 22.04.
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

# Update system and install required packages.
function update_and_install() {
    echo "Updating system packages..."
    apt update && apt upgrade -y

    echo "Installing required packages (unbound, dnsdist, certbot, dnsutils)..."
    apt install -y unbound dnsdist certbot dnsutils curl
}

# Configure Unbound as a local DNS resolver.
function configure_unbound() {
    echo "Configuring Unbound as local DNS resolver..."
    mkdir -p /etc/unbound/unbound.conf.d
    cat << 'EOF' > /etc/unbound/unbound.conf.d/doh.conf
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

# Obtain TLS certificate using certbot (standalone mode).
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

# Configure DNSDist to serve DoH.
function configure_dnsdist() {
    echo "Configuring DNSDist for DoH..."
    # Backup existing configuration if exists
    if [ -f /etc/dnsdist/dnsdist.conf ]; then
        mv /etc/dnsdist/dnsdist.conf /etc/dnsdist/dnsdist.conf.bak.$(date +%s)
    fi

    cat <<EOF > /etc/dnsdist/dnsdist.conf
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

# Run tests to verify Unbound and the DoH endpoint.
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

# Main function to run all steps interactively.
function main() {
    check_root
    check_os
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

# Run the main function.
main
