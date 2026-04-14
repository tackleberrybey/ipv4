#!/bin/bash

#############################################
# Elite Proxy Setup Script v4.1 (Safe)
# Sets up HTTP anonymous proxy with 3proxy
#
# Main fixes vs v4.0:
# - Applies conntrack settings through /etc/sysctl.d
# - Verifies kernel values after apply
# - Removes automatic conntrack flush from diagnostics
# - Aligns conntrack TCP timeouts with proxy idle timeouts
# - Avoids overly aggressive TCP retry tuning
#############################################

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

DEFAULT_HTTP_PORT=3128
CONNTRACK_MAX=262144
PROXY_DIR="/etc/3proxy"
PROXY_BIN="$PROXY_DIR/bin/3proxy"
PROXY_CFG="$PROXY_DIR/3proxy.cfg"
PROXY_LOG="$PROXY_DIR/logs"
PROXY_PID="/run/3proxy.pid"
WORK_DIR="/root/3proxy-install"
SYSCTL_FILE="/etc/sysctl.d/99-elite-proxy.conf"
LIMITS_FILE="/etc/security/limits.d/99-elite-proxy.conf"

print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}    ${BOLD}Elite Proxy Setup v4.1${NC}         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}        3proxy Safe Edition        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}    Conntrack + Stability Fixes    ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
    echo ""
}

print_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() { echo -e "${GREEN}OK${NC} $1"; }
print_error()   { echo -e "${RED}ERR${NC} $1"; }
print_warning() { echo -e "${YELLOW}WARN${NC} $1"; }
print_info()    { echo -e "${CYAN}INFO${NC} $1"; }

error_exit() {
    print_error "$1"
    echo ""
    print_warning "Installation failed. Cleaning up working directory."
    cleanup
    exit 1
}

cleanup() {
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root. Use: sudo bash proxy_setup_v4_1_safe.sh"
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
    if ! ping -c 1 8.8.8.8 > /dev/null 2>&1; then
        error_exit "No internet connection detected. Please check your network."
    fi
}

check_existing_installation() {
    echo -n "Checking for existing installation... "

    if systemctl list-units --full -all | grep -q "3proxy.service"; then
        print_warning "Existing 3proxy installation detected"

        echo -n "Stopping existing 3proxy service... "
        systemctl stop 3proxy > /dev/null 2>&1 || true
        sleep 2
        print_success "Service stopped"

        echo -n "Disabling existing service... "
        systemctl disable 3proxy > /dev/null 2>&1 || true
        print_success "Service disabled"

        echo -n "Killing any remaining 3proxy processes... "
        pkill -9 3proxy > /dev/null 2>&1 || true
        sleep 1
        print_success "Processes terminated"

        echo -n "Removing old installation... "
        rm -rf "$PROXY_DIR" > /dev/null 2>&1 || true
        rm -f /etc/systemd/system/3proxy.service > /dev/null 2>&1 || true
        rm -rf /etc/systemd/system/3proxy.service.d > /dev/null 2>&1 || true
        systemctl daemon-reload > /dev/null 2>&1 || true
        print_success "Old installation removed"

        echo ""
    else
        print_success "No existing installation found"
    fi
}

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

    LOCAL_IP=$(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -n1)

    if [ -z "$LOCAL_IP" ]; then
        error_exit "Could not detect local IP address"
    fi

    echo -e "${BOLD}Public IP:${NC} ${GREEN}$PUBLIC_IP${NC}"
    echo -e "${BOLD}Local IP:${NC}  ${GREEN}$LOCAL_IP${NC}"

    if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
        USE_NAT=true
        BIND_IP=""
        print_warning "NAT environment detected (cloud or NAT gateway)"
        print_info "Will configure 3proxy without external bind IP"
    else
        USE_NAT=false
        BIND_IP="-e$PUBLIC_IP"
        print_success "Direct IP assignment detected"
    fi

    SERVER_IP="$PUBLIC_IP"
    print_separator
    echo ""
}

get_user_input() {
    print_separator
    echo -e "${BOLD}Configuration${NC}"
    print_separator
    echo ""

    while true; do
        read -r -p "Enter proxy username: " PROXY_USER
        if [ -z "$PROXY_USER" ]; then
            print_error "Username cannot be empty"
        else
            break
        fi
    done

    while true; do
        read -r -s -p "Enter proxy password: " PROXY_PASS
        echo ""
        if [ -z "$PROXY_PASS" ]; then
            print_error "Password cannot be empty"
        else
            read -r -s -p "Confirm password: " PROXY_PASS_CONFIRM
            echo ""
            if [ "$PROXY_PASS" != "$PROXY_PASS_CONFIRM" ]; then
                print_error "Passwords do not match"
            else
                break
            fi
        fi
    done

    while true; do
        read -r -p "HTTP port [$DEFAULT_HTTP_PORT]: " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}

        if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1024 ] || [ "$HTTP_PORT" -gt 65535 ]; then
            print_error "Invalid HTTP port. Must be between 1024 and 65535"
        else
            break
        fi
    done

    echo ""
}

confirm_installation() {
    echo -e "${BOLD}Installation Summary:${NC}"
    echo ""
    echo "  Server IP    : $SERVER_IP"
    echo "  Username     : $PROXY_USER"
    echo "  Password     : ${PROXY_PASS//?/*}"
    echo "  HTTP Port    : $HTTP_PORT"
    echo "  Conntrack    : $CONNTRACK_MAX"
    echo "  Diagnose     : Safe mode (no automatic conntrack flush)"
    if [ "$USE_NAT" = true ]; then
        echo "  Environment  : NAT"
    else
        echo "  Environment  : Direct IP"
    fi
    echo ""

    read -r -p "Proceed with installation? (y/n): " -n 1 REPLY
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    echo ""
}

setup_swap() {
    print_separator
    echo -e "${BOLD}Configuring swap...${NC}"
    print_separator
    echo ""

    if [ "$(swapon --show | wc -l)" -eq 0 ]; then
        echo -n "Creating 2GB swap file... "
        fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 > /dev/null 2>&1
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null 2>&1
        swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        print_success "2GB swap created"
    else
        print_success "Swap already exists"
    fi

    echo ""
}

install_dependencies() {
    print_separator
    echo -e "${BOLD}Installing dependencies...${NC}"
    print_separator
    echo ""

    echo -n "Updating package lists... "
    if apt-get update -qq > /dev/null 2>&1; then
        print_success "System updated"
    else
        error_exit "Failed to update package lists"
    fi

    PACKAGES="build-essential gcc g++ make curl wget git ufw fail2ban libevent-dev conntrack dnsutils"

    echo -n "Installing packages... "
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PACKAGES > /dev/null 2>&1; then
        print_success "Dependencies installed"
    else
        error_exit "Failed to install dependencies"
    fi

    echo ""
}

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
        print_success "Downloaded"
    else
        error_exit "Failed to download 3proxy"
    fi

    echo -n "Extracting archive... "
    if tar -xzf 3proxy.tar.gz; then
        print_success "Extracted"
    else
        error_exit "Failed to extract 3proxy"
    fi

    cd "3proxy-${PROXY_VERSION}" || error_exit "Failed to enter source directory"

    echo -n "Configuring anonymous mode... "
    sed -i '1i #define ANONYMOUS 1' src/proxy.h
    print_success "Anonymous mode enabled"

    echo -n "Compiling 3proxy... "
    if make -f Makefile.Linux > /tmp/3proxy_compile.log 2>&1; then
        print_success "Compiled successfully"
    else
        print_error "Compilation failed"
        tail -20 /tmp/3proxy_compile.log
        error_exit "See compile log above"
    fi

    echo -n "Installing 3proxy... "
    mkdir -p "$PROXY_DIR"/bin "$PROXY_DIR"/logs
    pkill -9 3proxy > /dev/null 2>&1 || true
    sleep 1
    if cp bin/3proxy "$PROXY_BIN" && chmod +x "$PROXY_BIN"; then
        print_success "Installed to $PROXY_DIR"
    else
        error_exit "Failed to install 3proxy binary"
    fi

    echo ""
}

configure_dns() {
    print_separator
    echo -e "${BOLD}Configuring DNS...${NC}"
    print_separator
    echo ""

    echo -n "Setting DNS servers... "
    if systemctl is-active --quiet systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/proxy.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8 8.8.4.4
FallbackDNS=1.0.0.1
DNSStubListener=yes
EOF
        systemctl restart systemd-resolved > /dev/null 2>&1
        print_success "Configured via systemd-resolved"
    else
        cp /etc/resolv.conf /etc/resolv.conf.proxy-backup.$(date +%s) 2>/dev/null || true
        cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
        print_success "Configured via resolv.conf"
    fi

    echo -n "Testing DNS resolution... "
    if nslookup google.com 1.1.1.1 > /dev/null 2>&1; then
        print_success "DNS working"
    else
        print_warning "DNS test failed, but continuing"
    fi

    echo ""
}

configure_system() {
    print_separator
    echo -e "${BOLD}Configuring kernel and limits...${NC}"
    print_separator
    echo ""

    echo -n "Configuring limits... "
    mkdir -p /etc/security/limits.d
    cat > "$LIMITS_FILE" <<EOF
* soft nofile 100000
* hard nofile 100000
* soft nproc 100000
* hard nproc 100000
EOF
    print_success "Limits written to $LIMITS_FILE"

    echo -n "Loading conntrack module... "
    modprobe nf_conntrack > /dev/null 2>&1 || true
    print_success "Conntrack module checked"

    echo -n "Writing sysctl config... "
    cat > "$SYSCTL_FILE" <<EOF
# Elite Proxy v4.1 - safe kernel tuning

fs.file-max = 2097152

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 1440000

# Keep retries sane for slow-but-valid sites.
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_abort_on_overflow = 0

net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_orphans = 65536

# Conntrack sized for crawler workloads.
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    print_success "Sysctl file written to $SYSCTL_FILE"

    echo -n "Applying sysctl settings... "
    if sysctl --system > /tmp/3proxy_sysctl.log 2>&1; then
        print_success "Kernel settings applied"
    else
        print_error "sysctl apply failed"
        tail -20 /tmp/3proxy_sysctl.log
        error_exit "Kernel settings could not be applied"
    fi

    echo -n "Verifying conntrack settings... "
    ACTUAL_CONNTRACK_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
    ACTUAL_ESTABLISHED_TIMEOUT=$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || echo 0)

    if [ "$ACTUAL_CONNTRACK_MAX" -lt "$CONNTRACK_MAX" ]; then
        print_error "Expected nf_conntrack_max >= $CONNTRACK_MAX, got $ACTUAL_CONNTRACK_MAX"
        error_exit "Conntrack tuning did not apply"
    fi

    print_success "nf_conntrack_max=$ACTUAL_CONNTRACK_MAX established_timeout=$ACTUAL_ESTABLISHED_TIMEOUT"

    echo -n "Current conntrack usage... "
    CURRENT_CONNTRACK=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    print_success "$CURRENT_CONNTRACK / $ACTUAL_CONNTRACK_MAX"

    echo ""
}

configure_3proxy() {
    print_separator
    echo -e "${BOLD}Configuring 3proxy...${NC}"
    print_separator
    echo ""

    echo -n "Ensuring directories exist... "
    mkdir -p "$PROXY_DIR/bin" "$PROXY_LOG"
    print_success "Directories verified"

    echo -n "Creating proxy configuration... "
    cat > "$PROXY_CFG" <<EOF
# 3proxy configuration - Elite Proxy v4.1 Safe

daemon
pidfile $PROXY_PID
maxconn 5000

# DNS handled by OS.

# ClientRead ClientWrite ServerRead ServerWrite ServerConnect ClientIdle Resolve ServerIdle
timeouts 10 10 110 110 30 600 15 600

users $PROXY_USER:CL:$PROXY_PASS

auth strong
allow $PROXY_USER
proxy -p$HTTP_PORT -a -n -i0.0.0.0 $BIND_IP

flush
EOF

    chmod 600 "$PROXY_CFG"
    print_success "Configuration file created"
    print_success "HTTP proxy configured on port $HTTP_PORT"
    if [ "$USE_NAT" = true ]; then
        print_success "NAT compatibility enabled"
    fi

    echo ""
}

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
    ufw allow "$HTTP_PORT"/tcp > /dev/null 2>&1

    if [ "$UFW_WAS_ACTIVE" = false ]; then
        echo "y" | ufw enable > /dev/null 2>&1
    else
        ufw reload > /dev/null 2>&1
    fi

    print_success "Firewall configured"
    print_success "Port $HTTP_PORT opened"

    if [ "$USE_NAT" = true ]; then
        echo ""
        print_warning "NAT environment detected"
        print_info "Also open port $HTTP_PORT in your cloud firewall or security group"
    fi

    echo ""
}

setup_service() {
    print_separator
    echo -e "${BOLD}Setting up auto-start...${NC}"
    print_separator
    echo ""

    echo -n "Creating systemd service... "
    cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server (Safe v4.1)
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
        error_exit "Failed to enable 3proxy service"
    fi

    echo ""
}

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
            error_exit "Service failed to start"
        fi
    else
        echo ""
        print_error "Failed to start 3proxy"
        journalctl -u 3proxy -n 20 --no-pager
        error_exit "Service failed to start"
    fi

    echo ""
}

test_proxy() {
    print_separator
    echo -e "${BOLD}Testing proxy...${NC}"
    print_separator
    echo ""

    sleep 3

    TEST_OUTPUT=$(curl -s -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" --max-time 15 -w "\n%{http_code}|%{time_total}" http://ifconfig.me 2>/dev/null)
    if [ $? -eq 0 ]; then
        HTTP_IP=$(printf '%s\n' "$TEST_OUTPUT" | head -n 1)
        HTTP_CODE=$(printf '%s\n' "$TEST_OUTPUT" | tail -n 1 | cut -d'|' -f1)
        HTTP_TIME=$(printf '%s\n' "$TEST_OUTPUT" | tail -n 1 | cut -d'|' -f2)
        HTTP_TIME_MS=$(awk "BEGIN {printf \"%.0f\", $HTTP_TIME * 1000}")

        if [ "$HTTP_CODE" = "200" ]; then
            print_success "HTTP proxy working"
            echo "    External IP    : $HTTP_IP"
            echo "    Response time  : ${HTTP_TIME_MS}ms"
        else
            print_warning "HTTP proxy returned status $HTTP_CODE"
        fi
    else
        print_warning "Local proxy curl test failed"
    fi

    CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
    print_info "Conntrack usage after test: $CURRENT / $MAX"
    echo ""
}

save_details() {
    DETAILS_FILE="/root/proxy_details.txt"

    cat > "$DETAILS_FILE" <<EOF
=======================================
Elite Proxy Server v4.1 Safe
=======================================

Server IP : $SERVER_IP
Username  : $PROXY_USER
Password  : $PROXY_PASS
HTTP Port : $HTTP_PORT

HTTP Proxy:
$SERVER_IP:$HTTP_PORT:$PROXY_USER:$PROXY_PASS

Connection String:
http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT

Date        : $(date)
Environment : $([ "$USE_NAT" = true ] && echo "NAT" || echo "Direct IP")

Kernel verification:
nf_conntrack_count = $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)
nf_conntrack_max   = $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)

Useful commands:
- Restart  : systemctl restart 3proxy
- Status   : systemctl status 3proxy --no-pager
- Logs     : journalctl -u 3proxy -f
- Monitor  : /root/monitor_proxy.sh
- Diagnose : /root/diagnose_proxy.sh
EOF

    chmod 600 "$DETAILS_FILE"
}

create_monitoring_script() {
    print_separator
    echo -e "${BOLD}Creating monitoring tools...${NC}"
    print_separator
    echo ""

    echo -n "Creating monitoring script... "
    cat > /root/monitor_proxy.sh <<EOF
#!/bin/bash
echo "===================================="
echo "       3proxy Status Monitor        "
echo "===================================="
echo "Timestamp: \\$(date)"
echo ""

echo "Service status"
if systemctl is-active --quiet 3proxy; then
    echo "OK running"
    echo "Started: \\$(systemctl show 3proxy --property=ActiveEnterTimestamp --value)"
else
    echo "ERR stopped"
fi
echo ""

CURRENT=\\$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
MAX=\\$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
echo "Conntrack: \\$CURRENT / \\$MAX"
if [ "\\$MAX" -gt 0 ] && [ "\\$CURRENT" -gt \\$(( MAX * 80 / 100 )) ]; then
    echo "WARN conntrack above 80%"
else
    echo "OK conntrack healthy"
fi
echo ""

echo "TCP states"
ss -ant | awk '{print \\$1}' | sort | uniq -c | sort -nr
echo ""

echo "3proxy resources"
PID=\\$(pgrep 3proxy | head -n1)
if [ -n "\\$PID" ]; then
    ps -fp "\\$PID"
    ps -T -p "\\$PID" | wc -l | awk '{print "Threads: " \\$1}'
fi
free -h | grep Mem
echo ""

echo "Port ${HTTP_PORT} established"
ss -ant | grep ":${HTTP_PORT}" | grep -c ESTAB
EOF
    chmod +x /root/monitor_proxy.sh
    print_success "Monitoring script created"

    echo -n "Creating diagnostic script... "
    cat > /root/diagnose_proxy.sh <<EOF
#!/bin/bash
set -u

echo "Running diagnostics..."
echo ""

FORCE_FLUSH=false
if [ "\\${1:-}" = "--force-flush" ]; then
    FORCE_FLUSH=true
fi

if ! systemctl is-active --quiet 3proxy; then
    echo "WARN service not running, restarting..."
    systemctl restart 3proxy
    sleep 2
fi

CURRENT=\\$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
MAX=\\$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
echo "Conntrack usage: \\$CURRENT / \\$MAX"

if [ "\\$MAX" -gt 0 ] && [ "\\$CURRENT" -gt \\$(( MAX * 80 / 100 )) ]; then
    echo "WARN conntrack above 80%"
    if [ "\\$FORCE_FLUSH" = true ]; then
        echo "WARN force flushing conntrack table"
        conntrack -F > /dev/null 2>&1 || true
    else
        echo "INFO not flushing automatically"
        echo "INFO use: /root/diagnose_proxy.sh --force-flush"
    fi
fi

if ! nslookup google.com 1.1.1.1 > /dev/null 2>&1; then
    echo "WARN DNS issue detected"
fi

CFG_USER=\\$(awk '/^users / {split(\\$2, a, ":"); print a[1]; exit}' /etc/3proxy/3proxy.cfg)
CFG_PASS=\\$(awk '/^users / {split(\\$2, a, ":"); print a[3]; exit}' /etc/3proxy/3proxy.cfg)
CFG_PORT=\\$(awk '/^proxy / {for (i=1; i<=NF; i++) if (\\$i ~ /^-p[0-9]+$/) {sub(/^-p/, "", \\$i); print \\$i; exit}}' /etc/3proxy/3proxy.cfg)

echo ""
echo "Testing proxy..."
if curl -s -x "http://\\$CFG_USER:\\$CFG_PASS@127.0.0.1:\\$CFG_PORT" --max-time 10 http://ifconfig.me > /dev/null 2>&1; then
    echo "OK proxy is working"
else
    echo "ERR proxy test failed"
fi

echo ""
echo "Recent conntrack stats"
conntrack -S 2>/dev/null || true
EOF
    chmod +x /root/diagnose_proxy.sh
    print_success "Diagnostic script created"

    echo ""
}

display_results() {
    print_separator
    echo -e "${GREEN}${BOLD}Installation Complete${NC}"
    print_separator
    echo ""
    echo -e "${BOLD}HTTP Proxy:${NC}"
    echo -e "${GREEN}$SERVER_IP:$HTTP_PORT:$PROXY_USER:$PROXY_PASS${NC}"
    echo ""
    echo -e "${BOLD}Connection String:${NC}"
    echo -e "${GREEN}http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT${NC}"
    echo ""
    echo -e "${BOLD}Verified kernel values:${NC}"
    echo "  nf_conntrack_count = $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)"
    echo "  nf_conntrack_max   = $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)"
    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  systemctl status 3proxy --no-pager"
    echo "  /root/monitor_proxy.sh"
    echo "  /root/diagnose_proxy.sh"
    echo "  journalctl -u 3proxy -f"
    echo ""
}

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
    print_success "Setup completed successfully"
    echo ""
}

main
