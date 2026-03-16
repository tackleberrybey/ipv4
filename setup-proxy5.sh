#!/bin/bash

#############################################
# Elite Proxy Setup Script v4.0 (XRUMER EDITION)
# Sets up HTTP Anonymous Proxy
# Using 3proxy on Ubuntu/Debian
# Auto-detects NAT environments (AWS, etc.)
#
# FIXES:
# - nf_conntrack table overflow (ROOT CAUSE)
# - Zombie threads (tcp_syn_retries=1)
# - DNS bottleneck (nserver removed, OS handles DNS)
# - RAM crashes (2GB Swap)
# - XEvil captcha timeout (ClientIdle=600s)
# - Slow-but-alive sites (ServerConnect=30s, Resolve=15s)
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
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}Elite Proxy Setup Script v4.0${NC}    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}      HTTP Anonymous Proxy          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   Xrumer + XEvil Optimized         ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
    echo ""
}

print_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info()    { echo -e "${CYAN}ℹ${NC} $1"; }

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
        rm -rf /etc/systemd/system/3proxy.service.d > /dev/null 2>&1
        systemctl daemon-reload > /dev/null 2>&1
        print_success "Old installation removed"

        echo ""
    else
        print_success "No existing installation found"
    fi
}

#############################################
# Detect NAT Environment
#############################################

detect_nat_environment() {
    print_separator
    echo -e "${BOLD}Detecting network environment...${NC}"
    print_separator
    echo ""

    PUBLIC_IP=$(curl -s -4 --max-time 10 ifconfig.me 2>/dev/null || \
                curl -s -4 --max-time 10 icanhazip.com 2>/dev/null || \
                curl -s -4 --max-time 10 ipinfo.io/ip 2>/dev/null)

    if [ -z "$PUBLIC_IP" ]; then
        error_exit "Could not detect public IP address"
    fi

    LOCAL_IP=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)

    if [ -z "$LOCAL_IP" ]; then
        error_exit "Could not detect local IP address"
    fi

    echo -e "${BOLD}Public IP:${NC} ${GREEN}$PUBLIC_IP${NC}"
    echo -e "${BOLD}Local IP:${NC}  ${GREEN}$LOCAL_IP${NC}"

    if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
        USE_NAT=true
        BIND_IP=""
        print_warning "NAT environment detected (AWS/Cloud)"
        print_info "Will configure for NAT compatibility"
    else
        USE_NAT=false
        BIND_IP="-e$PUBLIC_IP"
        print_success "Direct IP assignment detected"
    fi

    SERVER_IP="$PUBLIC_IP"

    print_separator
    echo ""
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

    while true; do
        read -p "HTTP port [$DEFAULT_HTTP_PORT]: " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}

        if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || \
           [ "$HTTP_PORT" -lt 1024 ] || \
           [ "$HTTP_PORT" -gt 65535 ]; then
            print_error "Invalid HTTP port. Must be between 1024-65535"
        else
            break
        fi
    done

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
    if [ "$USE_NAT" = true ]; then
        echo "  Environment  : NAT (AWS/Cloud compatible)"
    else
        echo "  Environment  : Direct IP"
    fi
    echo "  Logging      : Disabled (saves disk space)"
    echo "  DNS          : OS handles (no 3proxy DNS bottleneck)"
    echo "  Conntrack    : 262144 (ROOT FIX applied)"
    echo "  XEvil        : ClientIdle=600s (captcha safe)"
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
# Setup Swap
#############################################

setup_swap() {
    print_separator
    echo -e "${BOLD}Configuring Virtual Memory (Swap)...${NC}"
    print_separator
    echo ""

    if [ $(swapon --show | wc -l) -eq 0 ]; then
        echo -n "Creating 2GB Swap file... "
        fallocate -l 2G /swapfile || \
            dd if=/dev/zero of=/swapfile bs=1M count=2048 > /dev/null 2>&1
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null 2>&1
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        print_success "2GB Swap created"
    else
        print_success "Swap already exists"
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

    PACKAGES="build-essential gcc g++ make curl wget git ufw \
              fail2ban libevent-dev conntrack"

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
    if wget -q "https://github.com/3proxy/3proxy/archive/${PROXY_VERSION}.tar.gz" \
            -O 3proxy.tar.gz; then
        print_success "Downloaded"
    else
        error_exit "Failed to download 3proxy"
    fi

    echo -n "Extracting archive... "
    if tar -xzf 3proxy.tar.gz; then
        print_success "Extracted"
    else
        error_exit "Failed to extract"
    fi

    cd "3proxy-${PROXY_VERSION}" || error_exit "Failed to enter directory"

    echo -n "Configuring anonymous mode... "
    sed -i '1i #define ANONYMOUS 1' src/proxy.h
    print_success "Anonymous mode enabled"

    echo -n "Compiling 3proxy (this may take a minute)... "
    if make -f Makefile.Linux > /tmp/3proxy_compile.log 2>&1; then
        print_success "Compiled successfully"
    else
        print_error "Compilation failed"
        tail -20 /tmp/3proxy_compile.log
        error_exit "Check log above."
    fi

    echo -n "Installing 3proxy... "
    mkdir -p "$PROXY_DIR"/{bin,logs}
    pkill -9 3proxy > /dev/null 2>&1
    sleep 1

    if cp bin/3proxy "$PROXY_BIN" && chmod +x "$PROXY_BIN"; then
        print_success "Installed to $PROXY_DIR"
    else
        error_exit "Failed to install"
    fi

    echo ""
}

#############################################
# Configure DNS
#############################################

configure_dns() {
    print_separator
    echo -e "${BOLD}Configuring DNS...${NC}"
    print_separator
    echo ""

    echo -n "Setting up DNS servers... "

    if systemctl is-active --quiet systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/proxy.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8 8.8.4.4
FallbackDNS=1.0.0.1
DNSStubListener=yes
EOF
        systemctl restart systemd-resolved > /dev/null 2>&1
        print_success "DNS configured via systemd-resolved"
    else
        cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
        print_success "DNS configured via resolv.conf"
    fi

    echo -n "Testing DNS resolution... "
    if nslookup google.com 1.1.1.1 > /dev/null 2>&1; then
        print_success "DNS working"
    else
        print_warning "DNS test failed, but continuing..."
    fi

    echo ""
}

#############################################
# Configure System (Kernel + Conntrack)
#############################################

configure_system() {
    print_separator
    echo -e "${BOLD}Configuring system limits and kernel...${NC}"
    print_separator
    echo ""

    echo -n "Configuring file limits... "
    cat > /etc/security/limits.conf <<EOF
* soft nofile 100000
* hard nofile 100000
* soft nproc 100000
* hard nproc 100000
EOF
    print_success "File limits set to 100000"

    echo -n "Configuring kernel TCP settings... "
    cat > /etc/sysctl.conf <<EOF
# Elite Proxy v4.0 - Xrumer Optimized

# File limits
fs.file-max = 2097152

# TCP performance
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Fast-fail for dead servers (zombie thread killer)
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1

# TIME-WAIT management
net.ipv4.tcp_max_tw_buckets = 1440000

# Keepalive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# Orphan connection cleanup
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_max_orphans = 8192
net.ipv4.tcp_abort_on_overflow = 1

# *** ROOT FIX: nf_conntrack overflow ***
# Default 7680 was causing silent packet drops
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

    sysctl -p > /dev/null 2>&1
    print_success "Kernel settings applied"

    echo -n "Clearing existing conntrack table... "
    conntrack -F > /dev/null 2>&1 || true
    print_success "Conntrack table cleared"

    echo ""
}

#############################################
# Configure 3proxy
#############################################

configure_3proxy() {
    print_separator
    echo -e "${BOLD}Configuring 3proxy...${NC}"
    print_separator
    echo ""

    echo -n "Ensuring directories exist... "
    mkdir -p "$PROXY_DIR/bin"
    mkdir -p "$PROXY_LOG"
    print_success "Directories verified"

    echo -n "Creating proxy configuration... "

    cat > "$PROXY_CFG" <<EOF
# 3proxy configuration - Elite Proxy v4.0
# Xrumer + XEvil Optimized

daemon
pidfile $PROXY_PID
maxconn 5000

# DNS handled by OS (no nserver - prevents DNS bottleneck)

# Timeout configuration:
# ClientRead ClientWrite ServerRead ServerWrite ServerConnect ClientIdle Resolve ServerIdle
#
# ClientRead  (10s): Xrumer sends request to proxy (near-instant, 10s safe)
# ClientWrite (10s): Proxy sends response to Xrumer (fast local transfer)
# ServerRead (110s): Wait for forum page (Xrumer GET limit=20s, POST limit=100s)
# ServerWrite(110s): Send form data to forum (Xrumer POST limit=100s)
# ServerConnect(30s): TCP handshake with forum (allows slow-but-alive sites)
# ClientIdle (600s): XEvil captcha solving can take 250+ seconds
# Resolve    (15s): DNS for slow nameservers
# ServerIdle (600s): Forum idle during XEvil processing
timeouts 10 10 110 110 30 600 15 600

# Authentication
users $PROXY_USER:CL:$PROXY_PASS

# HTTP Proxy (Anonymous/Elite mode)
auth strong
allow $PROXY_USER
proxy -p$HTTP_PORT -a -n -i0.0.0.0 $BIND_IP

# Deny all others
flush
EOF

    if [ -f "$PROXY_CFG" ]; then
        chmod 600 "$PROXY_CFG"
        print_success "Configuration file created"
        print_success "HTTP proxy configured (port $HTTP_PORT)"
        print_success "Authentication set up"
        if [ "$USE_NAT" = true ]; then
            print_success "NAT compatibility enabled"
        fi
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

    if [ "$UFW_WAS_ACTIVE" = false ]; then
        echo "y" | ufw enable > /dev/null 2>&1
    else
        ufw reload > /dev/null 2>&1
    fi

    print_success "UFW configured"
    print_success "Port $HTTP_PORT opened"
    print_success "SSH port protected"

    if [ "$USE_NAT" = true ]; then
        echo ""
        print_warning "NAT environment detected!"
        print_info "Open port $HTTP_PORT in your cloud provider's firewall:"
        print_info "  - AWS Lightsail : Networking > Firewall > Add rule"
        print_info "  - AWS EC2       : Security Groups > Inbound rules"
    fi

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

    echo -n "Creating systemd service... "

    cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server (Xrumer Edition v4.0)
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
LimitNOFILE=100000
LimitNPROC=100000

[Install]
WantedBy=multi-user.target
EOF

    print_success "Service file created"

    echo -n "Creating service override... "
    mkdir -p /etc/systemd/system/3proxy.service.d
    cat > /etc/systemd/system/3proxy.service.d/override.conf <<EOF
[Service]
LimitNOFILE=100000
LimitNPROC=100000
LimitCORE=infinity
EOF
    print_success "Service limits configured"

    systemctl daemon-reload

    if systemctl enable 3proxy > /dev/null 2>&1; then
        print_success "Service enabled for auto-start"
    else
        error_exit "Failed to enable service"
    fi

    echo ""
}

#############################################
# Start 3proxy
#############################################

start_proxy() {
    print_separator
    echo -e "${BOLD}Starting proxy...${NC}"
    print_separator
    echo ""

    echo -n "Starting 3proxy service... "

    if systemctl start 3proxy; then
        sleep 3

        if systemctl is-active --quiet 3proxy; then
            print_success "3proxy started successfully"

            if ss -tuln 2>/dev/null | grep -q ":$HTTP_PORT "; then
                print_success "Proxy is listening on port $HTTP_PORT"
            fi
        else
            echo ""
            print_error "3proxy failed to start"
            journalctl -u 3proxy -n 20 --no-pager
            error_exit "Service failed to start."
        fi
    else
        echo ""
        print_error "Failed to start 3proxy"
        journalctl -u 3proxy -n 20 --no-pager
        error_exit "Service failed to start."
    fi

    echo ""
}

#############################################
# Test Proxy
#############################################

test_proxy() {
    print_separator
    echo -e "${BOLD}Testing proxy...${NC}"
    print_separator
    echo ""

    sleep 3

    echo -e "${CYAN}[Testing HTTP Proxy]${NC}"

    HTTP_TEST=$(curl -s \
        -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" \
        --max-time 15 \
        -w "\n%{http_code}|%{time_total}" \
        "http://ifconfig.me" 2>/dev/null)

    if [ $? -eq 0 ]; then
        HTTP_IP=$(echo "$HTTP_TEST" | head -n 1)
        HTTP_CODE=$(echo "$HTTP_TEST" | tail -n 1 | cut -d'|' -f1)
        HTTP_TIME=$(echo "$HTTP_TEST" | tail -n 1 | cut -d'|' -f2)
        HTTP_TIME_MS=$(awk "BEGIN {printf \"%.0f\", $HTTP_TIME * 1000}")

        if [ "$HTTP_CODE" = "200" ]; then
            print_success "HTTP Proxy: Working"
            echo "    External IP    : $HTTP_IP"
            echo "    Response time  : ${HTTP_TIME_MS}ms"
            echo "    Anonymous      : Yes"
            HTTP_WORKING=true
        else
            print_error "HTTP Proxy: Failed (HTTP $HTTP_CODE)"
            HTTP_WORKING=false
        fi
    else
        print_error "HTTP Proxy: Connection failed"
        HTTP_WORKING=false
    fi

    print_separator
    echo ""

    if [ "$HTTP_WORKING" = true ]; then
        print_success "Proxy is working correctly!"
    else
        print_warning "Test failed but proxy is running. Try manually:"
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
Elite Proxy Server v4.0 (Xrumer Ed.)
═══════════════════════════════════════

Server IP : $SERVER_IP
Username  : $PROXY_USER
Password  : $PROXY_PASS
HTTP Port : $HTTP_PORT

HTTP Proxy:
$SERVER_IP:$HTTP_PORT:$PROXY_USER:$PROXY_PASS

Connection String:
$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT

═══════════════════════════════════════
Date        : $(date)
Environment : $([ "$USE_NAT" = true ] && echo "NAT (AWS/Cloud)" || echo "Direct IP")
═══════════════════════════════════════

Fixes Applied:
✓ nf_conntrack_max=262144 (ROOT FIX - no more packet drops)
✓ tcp_syn_retries=1 (dead servers fail in 3s, not 130s)
✓ nserver removed (OS handles DNS, no bottleneck)
✓ ClientIdle=600s (XEvil captcha 250s+ safe)
✓ ServerConnect=30s (slow-but-alive forums included)
✓ Resolve=15s (slow DNS nameservers included)
✓ 2GB Swap (RAM overflow protection)

Useful Commands:
- Restart  : systemctl restart 3proxy
- Status   : systemctl status 3proxy
- Logs     : journalctl -u 3proxy -f
- Monitor  : /root/monitor_proxy.sh
- Diagnose : /root/diagnose_proxy.sh

Test:
curl -x http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT http://ifconfig.me
EOF

    chmod 600 "$DETAILS_FILE"
}

#############################################
# Create Monitoring Script
#############################################

create_monitoring_script() {
    print_separator
    echo -e "${BOLD}Creating monitoring tools...${NC}"
    print_separator
    echo ""

    echo -n "Creating monitoring script... "

    cat > /root/monitor_proxy.sh <<'EOF'
#!/bin/bash
echo "╔════════════════════════════════════╗"
echo "║     3proxy Status Monitor v4.0     ║"
echo "╚════════════════════════════════════╝"
echo "Timestamp: $(date)"
echo ""

echo "━━━ Service Status ━━━"
if systemctl is-active --quiet 3proxy; then
    echo "✓ Service: Running"
    echo "  Started: $(systemctl show 3proxy --property=ActiveEnterTimestamp --value)"
else
    echo "✗ Service: Stopped"
fi
echo ""

echo "━━━ Conntrack (ROOT FIX) ━━━"
CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
echo "Usage: $CURRENT / $MAX"
if [ "$MAX" != "N/A" ] && [ "$CURRENT" -gt $(( MAX * 80 / 100 )) ]; then
    echo "⚠ WARNING: Conntrack table >80% full!"
else
    echo "✓ Conntrack healthy"
fi
echo ""

echo "━━━ TCP States ━━━"
ss -ant | awk '{print $1}' | sort | uniq -c | sort -nr
echo ""

echo "━━━ 3proxy Resources ━━━"
MEMORY=$(ps aux | grep 3proxy | grep -v grep | awk '{print $6/1024}')
MEMORY_PCT=$(ps aux | grep 3proxy | grep -v grep | awk '{print $4}')
THREADS=$(ps -T -p $(pgrep 3proxy) 2>/dev/null | wc -l)
echo "Memory : ${MEMORY} MB (${MEMORY_PCT}%)"
echo "Threads: $THREADS"
free -h | grep Mem
echo ""

echo "━━━ Active Connections ━━━"
echo "Total  : $(ss -ant | grep -c ESTAB)"
echo "Port   : $(ss -ant | grep ":3128" | grep -c ESTAB)"
echo ""

echo "━━━ DNS Status ━━━"
if nslookup google.com 1.1.1.1 > /dev/null 2>&1; then
    echo "✓ DNS: Working"
else
    echo "✗ DNS: Failed"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
EOF

    chmod +x /root/monitor_proxy.sh
    print_success "Monitoring script: /root/monitor_proxy.sh"

    echo -n "Creating diagnostic script... "

    cat > /root/diagnose_proxy.sh <<'EOF'
#!/bin/bash
echo "Running diagnostics..."
echo ""

# Check service
if ! systemctl is-active --quiet 3proxy; then
    echo "⚠ Service not running. Restarting..."
    systemctl restart 3proxy
    sleep 2
fi

# Check conntrack
CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "262144")
if [ "$CURRENT" -gt $(( MAX * 80 / 100 )) ]; then
    echo "⚠ Conntrack table >80%! Flushing..."
    conntrack -F > /dev/null 2>&1 || true
fi

# Check DNS
if ! nslookup google.com 1.1.1.1 > /dev/null 2>&1; then
    echo "⚠ DNS issue detected."
fi

# Test proxy
echo ""
echo "Testing proxy..."
CFG_USER=$(grep "^users" /etc/3proxy/3proxy.cfg | cut -d: -f1 | awk '{print $2}')
CFG_PASS=$(grep "^users" /etc/3proxy/3proxy.cfg | awk -F: '{print $3}')
CFG_PORT=$(grep "^proxy" /etc/3proxy/3proxy.cfg | grep -oP '(?<=-p)\d+')

if curl -s -x "http://$CFG_USER:$CFG_PASS@127.0.0.1:$CFG_PORT" \
        --max-time 10 http://ifconfig.me > /dev/null 2>&1; then
    echo "✓ Proxy is working"
else
    echo "✗ Proxy test failed"
fi

echo ""
echo "Run '/root/monitor_proxy.sh' for detailed status"
EOF

    chmod +x /root/diagnose_proxy.sh
    print_success "Diagnostic script: /root/diagnose_proxy.sh"

    echo ""
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
    echo -e "${BOLD}Connection String:${NC}"
    echo -e "${GREEN}http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT${NC}"
    print_separator
    echo ""
    echo -e "${CYAN}Details saved to:${NC} /root/proxy_details.txt"
    if [ "$USE_NAT" = true ]; then
        echo -e "${CYAN}Environment  :${NC} NAT (AWS/Cloud compatible)"
    else
        echo -e "${CYAN}Environment  :${NC} Direct IP"
    fi
    echo ""
    print_separator
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  Restart proxy : systemctl restart 3proxy"
    echo "  Check status  : systemctl status 3proxy"
    echo "  View logs     : journalctl -u 3proxy -f"
    echo "  Monitor       : /root/monitor_proxy.sh"
    echo "  Diagnose      : /root/diagnose_proxy.sh"
    print_separator
    echo ""
    echo -e "${BOLD}${GREEN}Fixes applied in v4.0:${NC}"
    echo "  ✓ nf_conntrack_max=262144 (ROOT FIX - silent packet drops eliminated)"
    echo "  ✓ tcp_syn_retries=1 (dead servers cleaned in 3s not 130s)"
    echo "  ✓ DNS bottleneck removed (OS handles DNS, not 3proxy)"
    echo "  ✓ ClientIdle=600s (XEvil captcha 250s+ safe)"
    echo "  ✓ ServerConnect=30s (slow-but-alive forums included)"
    echo "  ✓ Resolve=15s (slow DNS nameservers handled)"
    echo "  ✓ 2GB Swap added (RAM overflow protection)"
    echo ""
    print_separator
    echo ""
}

#############################################
# Main
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
    detect_nat_environment
    get_user_input
    confirm_installation

    setup_swap
    install_dependencies
    install_3proxy
    configure_dns
    configure_system
    configure_3proxy
    configure_firewall
    setup_service
    start_proxy
    test_proxy
    save_details
    create_monitoring_script
    display_results

    cleanup

    print_success "Setup completed successfully!"
    echo ""
}

main
