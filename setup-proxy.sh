#!/bin/bash

#############################################
# Elite Proxy Setup Script v1.0
# Sets up HTTP + SOCKS5 Anonymous Proxies
# Using 3proxy on Ubuntu/Debian
#############################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default ports
DEFAULT_HTTP_PORT=3128
DEFAULT_SOCKS_PORT=1080

# Installation paths
PROXY_DIR="/etc/3proxy"
PROXY_BIN="$PROXY_DIR/bin/3proxy"
PROXY_CFG="$PROXY_DIR/3proxy.cfg"
PROXY_LOG="$PROXY_DIR/logs"
WORK_DIR="/root/3proxy-install"

#############################################
# Helper Functions
#############################################

print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}Elite Proxy Setup Script v1.0${NC}    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   HTTP + SOCKS5 Anonymous Proxy   ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
    echo ""
}

print_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

# Error handler
error_exit() {
    print_error "$1"
    echo ""
    print_warning "Installation failed. Cleaning up..."
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

#############################################
# System Checks
#############################################

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        error_exit "This script must be run as root. Use: sudo bash script.sh"
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        error_exit "Cannot detect OS. This script supports Ubuntu/Debian only."
    fi

    case $OS in
        ubuntu|debian)
            print_success "$PRETTY_NAME detected"
            ;;
        *)
            error_exit "Unsupported OS: $OS. This script supports Ubuntu/Debian only."
            ;;
    esac
}

check_internet() {
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        error_exit "No internet connection detected. Please check your network."
    fi
}

#############################################
# Get User Input
#############################################

get_user_input() {
    print_separator
    echo -e "${BOLD}Configuration${NC}"
    print_separator
    echo ""

    # Username
    while true; do
        read -p "Enter proxy username: " PROXY_USER
        if [ -z "$PROXY_USER" ]; then
            print_error "Username cannot be empty"
        else
            break
        fi
    done

    # Password
    while true; do
        read -s -p "Enter proxy password: " PROXY_PASS
        echo ""
        if [ -z "$PROXY_PASS" ]; then
            print_error "Password cannot be empty"
        else
            read -s -p "Confirm password: " PROXY_PASS_CONFIRM
            echo ""
            if [ "$PROXY_PASS" != "$PROXY_PASS_CONFIRM" ]; then
                print_error "Passwords do not match"
            else
                break
            fi
        fi
    done

    # HTTP Port
    read -p "HTTP port [$DEFAULT_HTTP_PORT]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}

    # SOCKS5 Port
    read -p "SOCKS5 port [$DEFAULT_SOCKS_PORT]: " SOCKS_PORT
    SOCKS_PORT=${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}

    # Validate ports
    if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1024 ] || [ "$HTTP_PORT" -gt 65535 ]; then
        error_exit "Invalid HTTP port. Must be between 1024-65535"
    fi

    if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || [ "$SOCKS_PORT" -lt 1024 ] || [ "$SOCKS_PORT" -gt 65535 ]; then
        error_exit "Invalid SOCKS5 port. Must be between 1024-65535"
    fi

    if [ "$HTTP_PORT" -eq "$SOCKS_PORT" ]; then
        error_exit "HTTP and SOCKS5 ports must be different"
    fi

    echo ""
}

#############################################
# Detect Server IP
#############################################

detect_ip() {
    print_separator
    
    # Try multiple methods to get public IP
    SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || curl -s -4 ipinfo.io/ip 2>/dev/null)
    
    if [ -z "$SERVER_IP" ]; then
        # Fallback to local IP
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi

    if [ -z "$SERVER_IP" ]; then
        error_exit "Could not detect server IP address"
    fi

    echo -e "${BOLD}Detected server IP:${NC} ${GREEN}$SERVER_IP${NC}"
    print_separator
    echo ""
}

#############################################
# Confirm Installation
#############################################

confirm_installation() {
    echo -e "${BOLD}Installation Summary:${NC}"
    echo ""
    echo "  Server IP    : $SERVER_IP"
    echo "  Username     : $PROXY_USER"
    echo "  Password     : ${PROXY_PASS//?/*}"
    echo "  HTTP Port    : $HTTP_PORT"
    echo "  SOCKS5 Port  : $SOCKS_PORT"
    echo ""
    
    read -p "Proceed with installation? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    echo ""
}

#############################################
# Install Dependencies
#############################################

install_dependencies() {
    print_separator
    echo -e "${BOLD}Installing dependencies...${NC}"
    print_separator
    echo ""

    # Update system
    echo -n "Updating package lists... "
    if apt-get update -qq > /dev/null 2>&1; then
        print_success "System updated"
    else
        error_exit "Failed to update system"
    fi

    # Install required packages
    PACKAGES="build-essential gcc g++ make curl wget git ufw fail2ban"
    
    echo -n "Installing build tools... "
    if apt-get install -y -qq $PACKAGES > /dev/null 2>&1; then
        print_success "Build tools installed"
    else
        error_exit "Failed to install dependencies"
    fi

    echo ""
}

#############################################
# Download and Compile 3proxy
#############################################

install_3proxy() {
    print_separator
    echo -e "${BOLD}Installing 3proxy...${NC}"
    print_separator
    echo ""

    # Create working directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || error_exit "Failed to create working directory"

    # Download 3proxy
    echo -n "Downloading 3proxy... "
    PROXY_VERSION="0.9.4"
    if wget -q "https://github.com/3proxy/3proxy/archive/${PROXY_VERSION}.tar.gz" -O 3proxy.tar.gz; then
        print_success "3proxy downloaded"
    else
        error_exit "Failed to download 3proxy"
    fi

    # Extract
    echo -n "Extracting archive... "
    if tar -xzf 3proxy.tar.gz; then
        print_success "Archive extracted"
    else
        error_exit "Failed to extract 3proxy"
    fi

    cd "3proxy-${PROXY_VERSION}" || error_exit "Failed to enter 3proxy directory"

    # Enable anonymous mode
    echo -n "Configuring anonymous mode... "
    echo "#define ANONYMOUS 1" > src/define.txt
    
    # Insert the define at the beginning of proxy.h
    if grep -q "ANONYMOUS" src/proxy.h; then
        print_success "Anonymous mode already enabled"
    else
        sed -i '1i #define ANONYMOUS 1' src/proxy.h
        print_success "Anonymous mode enabled"
    fi

    # Compile
    echo -n "Compiling 3proxy (this may take a minute)... "
    if make -f Makefile.Linux > /dev/null 2>&1; then
        print_success "3proxy compiled successfully"
    else
        error_exit "Failed to compile 3proxy"
    fi

    # Install
    echo -n "Installing 3proxy... "
    mkdir -p "$PROXY_DIR"/{bin,logs}
    
    if cp bin/3proxy "$PROXY_BIN" && chmod +x "$PROXY_BIN"; then
        print_success "3proxy installed to $PROXY_DIR"
    else
        error_exit "Failed to install 3proxy"
    fi

    echo ""
}

#############################################
# Configure 3proxy
#############################################

configure_3proxy() {
    print_separator
    echo -e "${BOLD}Configuring proxies...${NC}"
    print_separator
    echo ""

    # Create config file
    cat > "$PROXY_CFG" <<EOF
# 3proxy configuration file
# Generated by Elite Proxy Setup Script

daemon
maxconn 1000
nscache 65536
nserver 1.1.1.1
nserver 8.8.8.8
timeouts 1 5 30 60 180 1800 15 60

# Logging
log "$PROXY_LOG/3proxy.log" D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30

# Authentication
auth strong
users $PROXY_USER:CL:$PROXY_PASS

# Allow authenticated user
allow $PROXY_USER

# HTTP Proxy (Anonymous/Elite mode)
proxy -p$HTTP_PORT -a -n -i$SERVER_IP -e$SERVER_IP

# SOCKS5 Proxy (Anonymous mode)
socks -p$SOCKS_PORT -a -n -i$SERVER_IP -e$SERVER_IP

# Deny all others
deny *
EOF

    if [ -f "$PROXY_CFG" ]; then
        chmod 600 "$PROXY_CFG"
        print_success "HTTP proxy configured (port $HTTP_PORT)"
        print_success "SOCKS5 proxy configured (port $SOCKS_PORT)"
        print_success "Authentication set up"
    else
        error_exit "Failed to create configuration file"
    fi

    echo ""
}

#############################################
# Configure Firewall
#############################################

configure_firewall() {
    print_separator
    echo -e "${BOLD}Configuring firewall...${NC}"
    print_separator
    echo ""

    # Check if UFW is active
    if systemctl is-active --quiet ufw; then
        UFW_WAS_ACTIVE=true
    else
        UFW_WAS_ACTIVE=false
    fi

    # Configure UFW
    echo -n "Configuring UFW rules... "
    
    # Allow SSH first (important!)
    ufw allow 22/tcp > /dev/null 2>&1
    
    # Allow proxy ports
    ufw allow $HTTP_PORT/tcp > /dev/null 2>&1
    ufw allow $SOCKS_PORT/tcp > /dev/null 2>&1
    
    # Enable UFW if it wasn't active
    if [ "$UFW_WAS_ACTIVE" = false ]; then
        echo "y" | ufw enable > /dev/null 2>&1
    else
        ufw reload > /dev/null 2>&1
    fi
    
    print_success "UFW configured"
    print_success "Port $HTTP_PORT opened (HTTP)"
    print_success "Port $SOCKS_PORT opened (SOCKS5)"
    print_success "SSH port protected"

    echo ""
}

#############################################
# Setup Systemd Service
#############################################

setup_service() {
    print_separator
    echo -e "${BOLD}Setting up auto-start...${NC}"
    print_separator
    echo ""

    # Create systemd service
    cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
PIDFile=/var/run/3proxy.pid
ExecStart=$PROXY_BIN $PROXY_CFG
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd
    systemctl daemon-reload

    # Enable service
    if systemctl enable 3proxy > /dev/null 2>&1; then
        print_success "Systemd service created"
        print_success "Service enabled for auto-start"
    else
        error_exit "Failed to enable 3proxy service"
    fi

    echo ""
}

#############################################
# Start 3proxy
#############################################

start_proxy() {
    print_separator
    echo -e "${BOLD}Starting proxies...${NC}"
    print_separator
    echo ""

    echo -n "Starting 3proxy service... "
    
    if systemctl start 3proxy; then
        sleep 2
        if systemctl is-active --quiet 3proxy; then
            print_success "3proxy started successfully"
        else
            error_exit "3proxy failed to start. Check logs: journalctl -u 3proxy -n 50"
        fi
    else
        error_exit "Failed to start 3proxy service"
    fi

    echo ""
}

#############################################
# Test Proxies
#############################################

test_proxies() {
    print_separator
    echo -e "${BOLD}Testing proxies...${NC}"
    print_separator
    echo ""

    # Wait a moment for proxies to fully initialize
    sleep 2

    # Test HTTP Proxy
    echo -e "${CYAN}[Testing HTTP Proxy]${NC}"
    
    HTTP_TEST=$(curl -s -x "http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT" \
                     --max-time 10 \
                     -w "\n%{http_code}|%{time_total}" \
                     "http://ifconfig.me" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        HTTP_IP=$(echo "$HTTP_TEST" | head -n 1)
        HTTP_CODE=$(echo "$HTTP_TEST" | tail -n 1 | cut -d'|' -f1)
        HTTP_TIME=$(echo "$HTTP_TEST" | tail -n 1 | cut -d'|' -f2)
        HTTP_TIME_MS=$(echo "$HTTP_TIME * 1000" | bc | cut -d'.' -f1)
        
        if [ "$HTTP_CODE" = "200" ]; then
            print_success "HTTP Proxy: Working"
            echo "    External IP: $HTTP_IP"
            echo "    Response time: ${HTTP_TIME_MS}ms"
            echo "    Anonymous: Yes"
            HTTP_WORKING=true
        else
            print_error "HTTP Proxy: Failed (HTTP $HTTP_CODE)"
            HTTP_WORKING=false
        fi
    else
        print_error "HTTP Proxy: Connection failed"
        HTTP_WORKING=false
    fi

    echo ""

    # Test SOCKS5 Proxy
    echo -e "${CYAN}[Testing SOCKS5 Proxy]${NC}"
    
    SOCKS_TEST=$(curl -s -x "socks5://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$SOCKS_PORT" \
                      --max-time 10 \
                      -w "\n%{http_code}|%{time_total}" \
                      "http://ifconfig.me" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        SOCKS_IP=$(echo "$SOCKS_TEST" | head -n 1)
        SOCKS_CODE=$(echo "$SOCKS_TEST" | tail -n 1 | cut -d'|' -f1)
        SOCKS_TIME=$(echo "$SOCKS_TEST" | tail -n 1 | cut -d'|' -f2)
        SOCKS_TIME_MS=$(echo "$SOCKS_TIME * 1000" | bc | cut -d'.' -f1)
        
        if [ "$SOCKS_CODE" = "200" ]; then
            print_success "SOCKS5 Proxy: Working"
            echo "    External IP: $SOCKS_IP"
            echo "    Response time: ${SOCKS_TIME_MS}ms"
            echo "    Anonymous: Yes"
            SOCKS_WORKING=true
        else
            print_error "SOCKS5 Proxy: Failed (HTTP $SOCKS_CODE)"
            SOCKS_WORKING=false
        fi
    else
        print_error "SOCKS5 Proxy: Connection failed"
        SOCKS_WORKING=false
    fi

    print_separator
    echo ""

    # Summary
    if [ "$HTTP_WORKING" = true ] && [ "$SOCKS_WORKING" = true ]; then
        print_success "All proxies are working correctly!"
    elif [ "$HTTP_WORKING" = true ] || [ "$SOCKS_WORKING" = true ]; then
        print_warning "Some proxies are working, but there were issues"
    else
        print_error "Proxy tests failed. Check configuration and firewall"
        print_info "Check logs: tail -f $PROXY_LOG/3proxy.log"
    fi

    echo ""
}

#############################################
# Save Proxy Details
#############################################

save_details() {
    DETAILS_FILE="/root/proxy_details.txt"
    
    cat > "$DETAILS_FILE" <<EOF
═══════════════════════════════════════
    Elite Proxy Server Details
═══════════════════════════════════════

Server IP: $SERVER_IP
Username: $PROXY_USER
Password: $PROXY_PASS

HTTP Proxy:
$SERVER_IP:$HTTP_PORT:$PROXY_USER:$PROXY_PASS

SOCKS5 Proxy:
$SERVER_IP:$SOCKS_PORT:$PROXY_USER:$PROXY_PASS

═══════════════════════════════════════
Installation Date: $(date)
═══════════════════════════════════════

Useful Commands:
- Restart proxy: systemctl restart 3proxy
- Check status: systemctl status 3proxy
- View logs: tail -f $PROXY_LOG/3proxy.log
- Stop proxy: systemctl stop 3proxy
- Start proxy: systemctl start 3proxy

Configuration file: $PROXY_CFG
Log directory: $PROXY_LOG
EOF

    chmod 600 "$DETAILS_FILE"
}

#############################################
# Display Final Results
#############################################

display_results() {
    print_separator
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║     Installation Complete! ✓       ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════╝${NC}"
    print_separator
    echo ""
    echo -e "${BOLD}Your proxy details:${NC}"
    print_separator
    echo ""
    echo -e "${BOLD}HTTP Proxy:${NC}"
    echo -e "${GREEN}$SERVER_IP:$HTTP_PORT:$PROXY_USER:$PROXY_PASS${NC}"
    echo ""
    echo -e "${BOLD}SOCKS5 Proxy:${NC}"
    echo -e "${GREEN}$SERVER_IP:$SOCKS_PORT:$PROXY_USER:$PROXY_PASS${NC}"
    print_separator
    echo ""
    echo -e "${CYAN}Details saved to:${NC} $DETAILS_FILE"
    echo -e "${CYAN}Logs location:${NC} $PROXY_LOG/3proxy.log"
    echo ""
    print_separator
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  Restart proxy : systemctl restart 3proxy"
    echo "  Check status  : systemctl status 3proxy"
    echo "  View logs     : tail -f $PROXY_LOG/3proxy.log"
    print_separator
    echo ""
}

#############################################
# Main Installation Flow
#############################################

main() {
    print_header
    
    echo "Checking system compatibility..."
    check_root
    check_os
    check_internet
    print_success "Running as root"
    print_success "Internet connection OK"
    echo ""
    
    get_user_input
    detect_ip
    confirm_installation
    
    install_dependencies
    install_3proxy
    configure_3proxy
    configure_firewall
    setup_service
    start_proxy
    test_proxies
    save_details
    display_results
    
    # Cleanup
    cleanup
    
    print_success "Setup completed successfully!"
    echo ""
}

# Run main function
main
