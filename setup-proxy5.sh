#!/bin/bash

#############################################
# Elite Proxy Setup Script v3.0 (XRUMER EDITION)
# Sets up HTTP Anonymous Proxy via 3proxy
# Optimized specifically for Xrumer 100s timeouts
# Fixes: Zombie Threads, RAM Leaks, TCP Exhaustion
#############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

DEFAULT_HTTP_PORT=3128
PROXY_DIR="/etc/3proxy"
PROXY_BIN="$PROXY_DIR/bin/3proxy"
PROXY_CFG="$PROXY_DIR/3proxy.cfg"
PROXY_LOG="$PROXY_DIR/logs"
PROXY_PID="/run/3proxy.pid"
WORK_DIR="/root/3proxy-install"

print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}Elite Proxy Setup v3.0 (XRUMER ED.)${NC}      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   Optimized for 100s Thread Lifetime       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   Fixed: Zombie Threads & RAM Leaks        ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
}

print_separator() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${CYAN}ℹ${NC} $1"; }

error_exit() {
    print_error "$1"
    echo ""
    print_warning "Installation failed. Cleaning up..."
    cleanup
    exit 1
}

cleanup() {
    if [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then error_exit "This script must be run as root. Use: sudo bash script.sh"; fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        error_exit "Cannot detect OS. Supports Ubuntu/Debian only."
    fi
    case $OS in
        ubuntu|debian) print_success "$PRETTY_NAME detected" ;;
        *) error_exit "Unsupported OS: $OS" ;;
    esac
}

check_existing_installation() {
    echo -n "Checking for existing installation... "
    if systemctl list-units --full -all | grep -q "3proxy.service"; then
        systemctl stop 3proxy > /dev/null 2>&1
        systemctl disable 3proxy > /dev/null 2>&1
        pkill -9 3proxy > /dev/null 2>&1
        rm -rf "$PROXY_DIR" /etc/systemd/system/3proxy.service /etc/systemd/system/3proxy.service.d > /dev/null 2>&1
        systemctl daemon-reload > /dev/null 2>&1
        print_success "Old installation removed completely"
    else
        print_success "No existing installation found"
    fi
}

setup_swap() {
    print_separator
    echo -e "${BOLD}Configuring Virtual Memory (Swap)...${NC}"
    print_separator
    if [ $(swapon --show | wc -l) -eq 0 ]; then
        echo -n "Creating 2GB Swap file for Xrumer stability... "
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 > /dev/null 2>&1
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null 2>&1
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        print_success "2GB Swap created successfully"
    else
        print_success "Swap memory already exists"
    fi
    echo ""
}

detect_nat_environment() {
    PUBLIC_IP=$(curl -s -4 --max-time 10 ifconfig.me 2>/dev/null || curl -s -4 --max-time 10 icanhazip.com 2>/dev/null)
    LOCAL_IP=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
    if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
        USE_NAT=true
        BIND_IP=""
    else
        USE_NAT=false
        BIND_IP="-e$PUBLIC_IP"
    fi
    SERVER_IP="$PUBLIC_IP"
}

get_user_input() {
    print_separator
    echo -e "${BOLD}Configuration${NC}"
    print_separator
    read -p "Enter proxy username: " PROXY_USER
    read -s -p "Enter proxy password: " PROXY_PASS
    echo ""
    read -p "HTTP port [$DEFAULT_HTTP_PORT]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}
    echo ""
}

install_dependencies() {
    print_separator
    echo -e "${BOLD}Installing dependencies...${NC}"
    print_separator
    apt-get update -qq > /dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential gcc g++ make curl wget git ufw fail2ban libevent-dev > /dev/null 2>&1
    print_success "Dependencies installed"
    echo ""
}

install_3proxy() {
    print_separator
    echo -e "${BOLD}Installing 3proxy...${NC}"
    print_separator
    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
    wget -q "https://github.com/3proxy/3proxy/archive/0.9.5.tar.gz" -O 3proxy.tar.gz
    tar -xzf 3proxy.tar.gz
    cd 3proxy-0.9.5
    sed -i '1i #define ANONYMOUS 1' src/proxy.h
    make -f Makefile.Linux > /dev/null 2>&1
    mkdir -p "$PROXY_DIR"/{bin,logs}
    cp bin/3proxy "$PROXY_BIN" && chmod +x "$PROXY_BIN"
    print_success "3proxy compiled and installed"
    echo ""
}

configure_dns() {
    if systemctl is-active --quiet systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/3proxy.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1
DNSStubListener=yes
EOF
        systemctl restart systemd-resolved > /dev/null 2>&1
    else
        cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
}

configure_system_limits() {
    print_separator
    echo -e "${BOLD}Configuring Kernel for Xrumer (Fast-Fail)...${NC}"
    print_separator
    
    cat > /etc/security/limits.conf <<EOF
* soft nofile 100000
* hard nofile 100000
* soft nproc 100000
* hard nproc 100000
EOF

    cat > /etc/sysctl.conf <<EOF
# Xrumer Optimized TCP Settings
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
EOF
    sysctl -p > /dev/null 2>&1
    print_success "Kernel TCP settings optimized for fast thread recycling"
    echo ""
}

configure_3proxy() {
    print_separator
    echo -e "${BOLD}Configuring 3proxy (Xrumer 100s Sync)...${NC}"
    print_separator
    
    cat > "$PROXY_CFG" <<EOF
daemon
pidfile $PROXY_PID
maxconn 5000
nscache 8192
nserver 1.1.1.1
nserver 8.8.8.8

# XRUMER TIMEOUT SYNC (110 seconds max)
# ClientRead ClientWrite ServerRead ServerWrite ServerConnect ClientIdle Resolve ServerIdle
timeouts 10 10 110 110 25 110 10 110

users $PROXY_USER:CL:$PROXY_PASS
auth strong
allow $PROXY_USER
proxy -p$HTTP_PORT -a -n -i0.0.0.0 $BIND_IP
flush
EOF
    chmod 600 "$PROXY_CFG"
    print_success "3proxy configured with 110s strict timeouts"
    echo ""
}

configure_firewall() {
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow $HTTP_PORT/tcp > /dev/null 2>&1
    if ! systemctl is-active --quiet ufw; then
        echo "y" | ufw enable > /dev/null 2>&1
    else
        ufw reload > /dev/null 2>&1
    fi
}

setup_service() {
    cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server (Xrumer Edition)
After=network.target

[Service]
Type=simple
PIDFile=$PROXY_PID
ExecStartPre=/bin/sleep 1
ExecStart=$PROXY_BIN $PROXY_CFG
ExecStop=/bin/kill -s TERM \$MAINPID
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=always
RestartSec=5s
LimitNOFILE=100000
LimitNPROC=100000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable 3proxy > /dev/null 2>&1
}

start_proxy() {
    systemctl start 3proxy
    sleep 2
    if systemctl is-active --quiet 3proxy; then
        print_success "Proxy started successfully on port $HTTP_PORT"
    else
        error_exit "Failed to start 3proxy"
    fi
}

test_proxy() {
    print_separator
    echo -e "${BOLD}Testing proxy connection...${NC}"
    print_separator
    sleep 3
    
    HTTP_TEST=$(curl -s -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" \
                     --max-time 15 \
                     -w "\n%{http_code}" \
                     "http://ifconfig.me" 2>/dev/null)
                     
    if [ $? -eq 0 ]; then
        HTTP_IP=$(echo "$HTTP_TEST" | head -n 1)
        HTTP_CODE=$(echo "$HTTP_TEST" | tail -n 1)
        
        if [ "$HTTP_CODE" = "200" ]; then
            print_success "Proxy is Working! (External IP: $HTTP_IP)"
        else
            print_error "Proxy test failed (HTTP $HTTP_CODE)"
        fi
    else
        print_error "Proxy connection failed during test"
    fi
    echo ""
}

main() {
    print_header
    check_root
    check_os
    check_existing_installation
    setup_swap
    detect_nat_environment
    get_user_input
    install_dependencies
    install_3proxy
    configure_dns
    configure_system_limits
    configure_3proxy
    configure_firewall
    setup_service
    start_proxy
    test_proxy
    
    print_separator
    echo -e "${GREEN}${BOLD}Installation Complete! ✓${NC}"
    print_separator
    echo -e "Proxy IP   : ${GREEN}$SERVER_IP${NC}"
    echo -e "Port       : ${GREEN}$HTTP_PORT${NC}"
    echo -e "Username   : ${GREEN}$PROXY_USER${NC}"
    echo -e "Password   : ${GREEN}$PROXY_PASS${NC}"
    echo ""
    echo -e "${BOLD}Xrumer Optimizations Applied:${NC}"
    echo "1. Timeouts synced to 110s (Matches your 100s Xrumer limit)"
    echo "2. 2GB Swap Memory added to prevent RAM crashes"
    echo "3. Kernel TCP Fast-Fail enabled (Kills dead connections in 10s)"
    echo "4. DNS Cache reduced to 8192 to save RAM"
    echo "5. Max connections increased to 5000"
    echo ""
    cleanup
}

main
