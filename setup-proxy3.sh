#!/bin/bash

#############################################
# Elite Proxy Setup Script v1.2
# Sets up HTTP + SOCKS5 Anonymous Proxies
# Using 3proxy on Ubuntu/Debian
# Logging disabled to save disk space
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
PROXY_PID="/var/run/3proxy.pid"
WORK_DIR="/root/3proxy-install"

#############################################
# Helper Functions
#############################################

print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}Elite Proxy Setup Script v1.2${NC}    ${CYAN}║${NC}"
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

error_exit() {
    print_error "$1"
    echo ""
    print_warning "Installation failed. Cleaning up..."
    cleanup
    exit 1
}

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

check_existing_installation() {
    echo -n "Checking for existing installation... "
    
    if systemctl list-units --full -all | grep -q "3proxy.service"; then
        print_warning "Existing 3proxy installation detected"
        
        echo -n "Stopping existing 3proxy service... "
        systemctl stop 3proxy > /dev/null 2>&1
        sleep 2
        print_success "Service stopped"
        
        echo -n "Disabling existing service... "
        systemctl disable 3proxy > /dev/null 2>&1
        print_success "Service disabled"
        
        echo -n "Killing any remaining 3proxy processes... "
        pkill -9 3proxy > /dev/null 2>&1
        sleep 1
        print_success "Processes terminated"
        
        echo -n "Removing old installation... "
        rm -rf "$PROXY_DIR" > /dev/null 2>&1
        rm -f /etc/systemd/system/3proxy.service > /dev/null 2>&1
        systemctl daemon-reload > /dev/null 2>&1
        print_success "Old installation removed"
        
        echo ""
    else
        print_success "No existing installation found"
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

    while true; do
        read -p "Enter proxy username: " PROXY_USER
        if [ -z "$PROXY_USER" ]; then
            print_error "Username cannot be empty"
        else
            break
        fi
    done

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

    read -p "HTTP port [$DEFAULT_HTTP_PORT]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}

    read -p "SOCKS5 port [$DEFAULT_SOCKS_PORT]: " SOCKS_PORT
    SOCKS_PORT=${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}

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
    
    SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || curl -s -4 ipinfo.io/ip 2>/dev/null)
    
    if [ -z "$SERVER_IP" ]; then
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
    echo "  Logging      : Disabled (saves disk space)"
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

    echo -n "Updating package lists... "
    if apt-get update -qq > /dev/null 2>&1; then
        print_success "System updated"
    else
        error_exit "Failed to update system"
    fi

    PACKAGES="build-essential gcc g++ make curl wget git ufw fail2ban libevent-dev"
    
    echo -n "Installing build tools... "
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PACKAGES > /dev/null 2>&1; then
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

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || error_exit "Failed to create working directory"

    echo -n "Downloading 3proxy... "
    PROXY_VERSION="0.9.5"
    if wget -q "https://github.com/3proxy/3proxy/archive/${PROXY_VERSION}.tar.gz" -O 3proxy.tar.gz; then
        print_success "3proxy downloaded"
    else
        error_exit "Failed to download 3proxy"
    fi

    echo -n "Extracting archive... "
    if tar -xzf 3proxy.tar.gz; then
        print_success "Archive extracted"
    else
        error_exit "Failed to extract 3proxy"
    fi

    cd "3proxy-${PROXY_VERSION}" || error_exit "Failed to enter 3proxy directory"

    echo -n "Configuring anonymous mode... "
    sed -i '1i #define ANONYMOUS 1' src/proxy.h
    print_success "Anonymous mode enabled"

    echo -n "Compiling 3proxy (this may take a minute)... "
    if make -f Makefile.Linux > /tmp/3proxy_compile.log 2>&1; then
        print_success "3proxy compiled successfully"
    else
        print_error "Failed to compile 3proxy"
        echo ""
        print_info "Compilation log:"
        tail -20 /tmp/3proxy_compile.log
        error_exit "Compilation failed. Check log above."
    fi

    echo -n "Installing 3proxy... "
    mkdir -p "$PROXY_DIR"/{bin,logs}
    
    pkill -9 3proxy > /dev/null 2>&1
    sleep 1
    
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

    echo -n "Configuring system limits... "
    
    if ! grep -q "nofile 65535" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
EOF
    fi

    if ! grep -q "fs.file-max = 65535" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf <<EOF
fs.file-max = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    fi
    
    sysctl -p > /dev/null 2>&1
    
    print_success "System limits configured"

    echo -n "Creating configuration directories... "
    mkdir -p "$PROXY_DIR"
    mkdir -p "$PROXY_LOG"
    print_success "Directories created"

    cat > "$PROXY_CFG" <<EOF
# 3proxy configuration file
# Generated by Elite Proxy Setup Script v1.2
# Logging disabled to save disk space

daemon
pidfile $PROXY_PID
maxconn 2000
nscache 65536
nserver 1.1.1.1
nserver 8.8.8.8
timeouts 1 5 30 60 180 1800 15 60

# Logging disabled to prevent disk space issues
# To enable logging, uncomment the following lines:
# log "$PROXY_LOG/3proxy.log" D
# logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
# rotate 1

# Authentication
users $PROXY_USER:CL:$PROXY_PASS

# HTTP Proxy (Anonymous/Elite mode)
auth strong
allow $PROXY_USER
proxy -p$HTTP_PORT -a -n -i0.0.0.0 -e$SERVER_IP

# SOCKS5 Proxy (Anonymous mode)
auth strong
allow $PROXY_USER
socks -p$SOCKS_PORT -i0.0.0.0 -e$SERVER_IP

# Deny all others
flush
EOF

    if [ -f "$PROXY_CFG" ]; then
        chmod 600 "$PROXY_CFG"
        print_success "HTTP proxy configured (port $HTTP_PORT)"
        print_success "SOCKS5 proxy configured (port $SOCKS_PORT)"
        print_success "Authentication set up"
        print_success "Logging disabled (saves disk space)"
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

    if systemctl is-active --quiet ufw; then
        UFW_WAS_ACTIVE=true
    else
        UFW_WAS_ACTIVE=false
    fi

    echo -n "Configuring UFW rules... "
    
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow $HTTP_PORT/tcp > /dev/null 2>&1
    ufw allow $SOCKS_PORT/tcp > /dev/null 2>&1
    
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

    cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
PIDFile=$PROXY_PID
ExecStartPre=/bin/sleep 1
ExecStart=$PROXY_BIN $PROXY_CFG
ExecStop=/bin/kill -s TERM \$MAINPID
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

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
        sleep 3
        
        if systemctl is-active --quiet 3proxy; then
            print_success "3proxy started successfully"
            
            sleep 1
            if command -v netstat &> /dev/null; then
                if netstat -tuln 2>/dev/null | grep -q ":$HTTP_PORT " && netstat -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
                    print_success "Proxies are listening on configured ports"
                fi
            fi
        else
            echo ""
            print_error "3proxy failed to start properly"
            print_info "Checking logs..."
            journalctl -u 3proxy -n 20 --no-pager
            error_exit "Service failed to start. Check logs above."
        fi
    else
        echo ""
        print_error "Failed to start 3proxy service"
        print_info "Checking logs..."
        journalctl -u 3proxy -n 20 --no-pager
        error_exit "Service failed to start. Check logs above."
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

    sleep 3

    echo -e "${CYAN}[Testing HTTP Proxy]${NC}"
    
    HTTP_TEST=$(curl -s -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" \
                     --max-time 15 \
                     -w "\n%{http_code}|%{time_total}" \
                     "http://ifconfig.me" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        HTTP_IP=$(echo "$HTTP_TEST" | head -n 1)
        HTTP_CODE=$(echo "$HTTP_TEST" | tail -n 1 | cut -d'|' -f1)
        HTTP_TIME=$(echo "$HTTP_TEST" | tail -n 1 | cut -d'|' -f2)
        
        if command -v bc &> /dev/null; then
            HTTP_TIME_MS=$(echo "$HTTP_TIME * 1000" | bc | cut -d'.' -f1)
        else
            HTTP_TIME_MS=$(awk "BEGIN {printf \"%.0f\", $HTTP_TIME * 1000}")
        fi
        
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

    echo -e "${CYAN}[Testing SOCKS5 Proxy]${NC}"
    
    SOCKS_TEST=$(curl -s -x "socks5://$PROXY_USER:$PROXY_PASS@127.0.0.1:$SOCKS_PORT" \
                      --max-time 15 \
                      -w "\n%{http_code}|%{time_total}" \
                      "http://ifconfig.me" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        SOCKS_IP=$(echo "$SOCKS_TEST" | head -n 1)
        SOCKS_CODE=$(echo "$SOCKS_TEST" | tail -n 1 | cut -d'|' -f1)
        SOCKS_TIME=$(echo "$SOCKS_TEST" | tail -n 1 | cut -d'|' -f2)
        
        if command -v bc &> /dev/null; then
            SOCKS_TIME_MS=$(echo "$SOCKS_TIME * 1000" | bc | cut -d'.' -f1)
        else
            SOCKS_TIME_MS=$(awk "BEGIN {printf \"%.0f\", $SOCKS_TIME * 1000}")
        fi
        
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

    if [ "$HTTP_WORKING" = true ] && [ "$SOCKS_WORKING" = true ]; then
        print_success "All proxies are working correctly!"
    elif [ "$HTTP_WORKING" = true ] || [ "$SOCKS_WORKING" = true ]; then
        print_warning "Some proxies are working, but there were issues with testing"
        print_info "The proxies are installed. You can test them manually."
    else
        print_warning "Proxy tests failed, but proxies are installed and running"
        print_info "This might be due to network conditions. Try testing manually:"
        echo "  curl -x http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT http://ifconfig.me"
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
Logging: Disabled (to save disk space)
═══════════════════════════════════════

Useful Commands:
- Restart proxy: systemctl restart 3proxy
- Check status: systemctl status 3proxy
- Stop proxy: systemctl stop 3proxy
- Start proxy: systemctl start 3proxy
- View systemd logs: journalctl -u 3proxy -f

Test Commands:
- Test HTTP: curl -x http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT http://ifconfig.me
- Test SOCKS5: curl -x socks5://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$SOCKS_PORT http://ifconfig.me

Configuration file: $PROXY_CFG

Note: Logging is disabled to prevent disk space issues.
To enable logging, edit $PROXY_CFG and uncomment the log lines.
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
    echo -e "${CYAN}Logging:${NC} Disabled (saves disk space)"
    echo ""
    print_separator
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  Restart proxy : systemctl restart 3proxy"
    echo "  Check status  : systemctl status 3proxy"
    echo "  View logs     : journalctl -u 3proxy -f"
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
    
    check_existing_installation
    
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
    
    cleanup
    
    print_success "Setup completed successfully!"
    echo ""
}

# Run main function
main
