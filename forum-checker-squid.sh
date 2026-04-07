#!/bin/bash

#############################################
# Squid Forward Proxy Setup Script v2.0
# Replaces 3proxy for forum-registration-checker
#
# Why Squid instead of 3proxy?
# - Multi-process architecture (workers)
# - Async I/O, handles thousands of concurrent connections
# - Battle-tested in production at massive scale
# - Native DNS resolver (no OS bottleneck)
# - No-cache mode uses ~30MB RAM per worker
#
# IMPORTANT:
# - Port 3128 korunuyor (Rust programında değişiklik yok)
# - Credentials aynı kalıyor (user:pass)
# - Anonymous/elite proxy headers
# - Caching tamamen kapalı (RAM tasarrufu)
#
# Kullanım: sudo bash proxy-squid-forum-checker.sh
#############################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

DEFAULT_PORT=3128

print_header() {
    clear
    echo -e "${CYAN}╔═════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}Squid Forward Proxy Setup v2.0${NC}         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  forum-registration-checker optimized   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Replaces 3proxy for high concurrency   ${CYAN}║${NC}"
    echo -e "${CYAN}╚═════════════════════════════════════════╝${NC}"
    echo ""
}

print_separator() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
print_success()   { echo -e "${GREEN}✓${NC} $1"; }
print_error()     { echo -e "${RED}✗${NC} $1"; }
print_warning()   { echo -e "${YELLOW}⚠${NC} $1"; }
print_info()      { echo -e "${CYAN}ℹ${NC} $1"; }

error_exit() {
    print_error "$1"
    exit 1
}

#############################################
# System Checks
#############################################

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root. Use: sudo bash $0"
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        error_exit "Cannot detect OS. Supports Debian/Ubuntu only."
    fi

    case $OS in
        ubuntu|debian)
            print_success "$PRETTY_NAME detected"
            ;;
        *)
            error_exit "Unsupported OS: $OS"
            ;;
    esac
}

detect_network() {
    print_separator
    echo -e "${BOLD}Detecting network environment...${NC}"
    echo ""

    PUBLIC_IP=$(curl -s -4 --max-time 10 ifconfig.me 2>/dev/null || \
                curl -s -4 --max-time 10 icanhazip.com 2>/dev/null || \
                curl -s -4 --max-time 10 ipinfo.io/ip 2>/dev/null)

    if [ -z "$PUBLIC_IP" ]; then
        error_exit "Could not detect public IP address"
    fi

    LOCAL_IP=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)

    echo -e "  Public IP: ${GREEN}$PUBLIC_IP${NC}"
    echo -e "  Local IP:  ${GREEN}$LOCAL_IP${NC}"

    if [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
        print_warning "NAT environment detected (AWS/Cloud)"
    else
        print_success "Direct IP assignment"
    fi

    SERVER_IP="$PUBLIC_IP"
    echo ""
}

#############################################
# Get User Input
#############################################

get_user_input() {
    print_separator
    echo -e "${BOLD}Configuration${NC}"
    echo ""

    while true; do
        read -p "Proxy username: " PROXY_USER
        [ -n "$PROXY_USER" ] && break
        print_error "Username cannot be empty"
    done

    while true; do
        read -s -p "Proxy password: " PROXY_PASS
        echo ""
        if [ -z "$PROXY_PASS" ]; then
            print_error "Password cannot be empty"
            continue
        fi
        read -s -p "Confirm password: " PROXY_PASS_CONFIRM
        echo ""
        if [ "$PROXY_PASS" != "$PROXY_PASS_CONFIRM" ]; then
            print_error "Passwords do not match"
        else
            break
        fi
    done

    while true; do
        read -p "HTTP port [$DEFAULT_PORT]: " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-$DEFAULT_PORT}
        if [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && [ "$HTTP_PORT" -ge 1024 ] && [ "$HTTP_PORT" -le 65535 ]; then
            break
        fi
        print_error "Invalid port. Must be 1024-65535"
    done

    # Detect RAM and set workers accordingly
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_RAM_MB" -le 1024 ]; then
        SQUID_WORKERS=2
    elif [ "$TOTAL_RAM_MB" -le 2048 ]; then
        SQUID_WORKERS=4
    else
        SQUID_WORKERS=6
    fi

    echo ""
    echo -e "${BOLD}Installation Summary:${NC}"
    echo ""
    echo "  Server IP    : $SERVER_IP"
    echo "  Username     : $PROXY_USER"
    echo "  Password     : ${PROXY_PASS//?/*}"
    echo "  Port         : $HTTP_PORT"
    echo "  RAM          : ${TOTAL_RAM_MB}MB"
    echo "  Squid workers: $SQUID_WORKERS"
    echo "  Caching      : Disabled (saves RAM)"
    echo "  DNS          : 1.1.1.1, 8.8.8.8, 8.8.4.4"
    echo "  Anonymous    : Yes (elite proxy)"
    echo ""

    read -p "Proceed? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
    echo ""
}

#############################################
# Remove 3proxy (if present)
#############################################

remove_3proxy() {
    print_separator
    echo -e "${BOLD}Removing 3proxy (if present)...${NC}"
    echo ""

    if systemctl list-units --full -all 2>/dev/null | grep -q "3proxy"; then
        systemctl stop 3proxy > /dev/null 2>&1 || true
        systemctl disable 3proxy > /dev/null 2>&1 || true
        sleep 1
        print_success "3proxy service stopped and disabled"
    else
        print_info "No 3proxy service found"
    fi

    pkill -9 3proxy > /dev/null 2>&1 || true

    # Remove 3proxy files but keep config as backup
    if [ -d /etc/3proxy ]; then
        cp /etc/3proxy/3proxy.cfg /root/3proxy.cfg.backup 2>/dev/null || true
        rm -rf /etc/3proxy
        print_success "3proxy removed (config backed up to /root/3proxy.cfg.backup)"
    fi

    rm -f /etc/systemd/system/3proxy.service
    rm -rf /etc/systemd/system/3proxy.service.d
    systemctl daemon-reload > /dev/null 2>&1 || true

    echo ""
}

#############################################
# Install Squid
#############################################

install_squid() {
    print_separator
    echo -e "${BOLD}Installing Squid...${NC}"
    echo ""

    echo -n "Updating package lists... "
    apt-get update -qq > /dev/null 2>&1
    print_success "Done"

    echo -n "Installing squid + apache2-utils (for htpasswd)... "
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq squid apache2-utils > /dev/null 2>&1
    print_success "Installed"

    # Stop squid before configuring
    systemctl stop squid > /dev/null 2>&1 || true

    # Verify squid binary
    if ! command -v squid &> /dev/null; then
        error_exit "Squid installation failed"
    fi

    # Find auth helper path
    NCSA_AUTH=""
    for path in \
        /usr/lib/squid/basic_ncsa_auth \
        /usr/lib64/squid/basic_ncsa_auth \
        /usr/libexec/squid/basic_ncsa_auth \
        /usr/lib/squid3/basic_ncsa_auth; do
        if [ -f "$path" ]; then
            NCSA_AUTH="$path"
            break
        fi
    done

    if [ -z "$NCSA_AUTH" ]; then
        error_exit "Could not find basic_ncsa_auth helper. Is squid installed correctly?"
    fi

    print_success "Auth helper found: $NCSA_AUTH"
    echo ""
}

#############################################
# Configure Squid
#############################################

configure_squid() {
    print_separator
    echo -e "${BOLD}Configuring Squid...${NC}"
    echo ""

    # Create password file
    echo -n "Creating auth credentials... "
    htpasswd -cb /etc/squid/passwd "$PROXY_USER" "$PROXY_PASS" > /dev/null 2>&1
    chmod 640 /etc/squid/passwd
    chown root:proxy /etc/squid/passwd 2>/dev/null || chown root:squid /etc/squid/passwd 2>/dev/null || true
    print_success "Credentials created"

    # Backup original config
    if [ -f /etc/squid/squid.conf ]; then
        cp /etc/squid/squid.conf /etc/squid/squid.conf.original
    fi

    echo -n "Writing Squid configuration... "

    cat > /etc/squid/squid.conf <<SQUIDEOF
# ══════════════════════════════════════════════════════════════════
# Squid Forward Proxy v2.0 — Forum Registration Checker
# ══════════════════════════════════════════════════════════════════
# Optimized for: 10M+ domain checking at high concurrency
# Mode: Forward proxy, no caching, anonymous/elite headers
# ══════════════════════════════════════════════════════════════════

# ── Workers ──────────────────────────────────────────────────────
# Multi-process mode. Each worker handles connections independently.
# 3proxy was single-process — this is the key upgrade.
workers $SQUID_WORKERS

# ── Port ─────────────────────────────────────────────────────────
http_port $HTTP_PORT

# ── DNS ──────────────────────────────────────────────────────────
# Squid has its own async DNS resolver — faster than OS resolver
# at high concurrency. No systemd-resolved bottleneck.
dns_nameservers 1.1.1.1 8.8.8.8 8.8.4.4
dns_timeout 15 seconds
positive_dns_ttl 1 hours
negative_dns_ttl 30 seconds

# ── No Caching ───────────────────────────────────────────────────
# Each domain is visited once — caching wastes RAM.
cache deny all
cache_mem 8 MB
maximum_object_size 0 bytes
memory_pools off

# ── File Descriptors ─────────────────────────────────────────────
max_filedescriptors 100000

# ── Timeouts ─────────────────────────────────────────────────────
# connect_timeout: TCP handshake with target site
#   30s — slow-but-alive forums included (matches Rust client's connect_timeout=20s + margin)
connect_timeout 30 seconds

# read_timeout: waiting for data from target after connection established
#   60s — forum pages can be slow to respond
read_timeout 60 seconds

# request_timeout: total time for initial request setup
#   60s — generous limit for the full request cycle
request_timeout 60 seconds

# client_idle_pconn_timeout: idle keep-alive from Rust client
#   30s — Rust client won't idle long, free resources quickly
client_idle_pconn_timeout 30 seconds

# pconn_timeout: idle keep-alive to target servers
#   15s — we don't revisit the same domain, free quickly
pconn_timeout 15 seconds

# forward_timeout: time to establish forward connection
#   30s — same as connect_timeout
forward_timeout 30 seconds

# shutdown_lifetime: how long to wait for active connections on shutdown
shutdown_lifetime 5 seconds

# ── Anonymous / Elite Proxy ──────────────────────────────────────
# Don't reveal proxy existence or client IP to target servers.
via off
forwarded_for delete

# Strip proxy-revealing headers from requests
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Forwarded deny all
request_header_access X-Real-IP deny all
request_header_access Proxy-Connection deny all

# Strip Squid-specific headers from responses
reply_header_access X-Squid-Error deny all
reply_header_access X-Cache deny all
reply_header_access X-Cache-Lookup deny all

# ── Access Control ───────────────────────────────────────────────
# Allow all ports (some forums run on non-standard ports)
acl SSL_ports port 1-65535
acl Safe_ports port 1-65535
acl CONNECT method CONNECT

# ── Authentication ───────────────────────────────────────────────
auth_param basic program $NCSA_AUTH /etc/squid/passwd
auth_param basic children 10 startup=4 idle=2
auth_param basic realm ForumCheckerProxy
auth_param basic credentialsttl 24 hours
acl authenticated proxy_auth REQUIRED

# ── Rules ────────────────────────────────────────────────────────
http_access allow CONNECT authenticated
http_access allow authenticated
http_access deny all

# ── Logging ──────────────────────────────────────────────────────
# Minimal logging — saves disk I/O and space.
# Enable access_log temporarily for debugging if needed.
access_log none
cache_store_log none
cache_log /var/log/squid/cache.log

# Suppress startup/version info
httpd_suppress_version_string on

# ── Performance ──────────────────────────────────────────────────
# Disable ICP (inter-cache protocol) — we're standalone
icp_port 0

# Don't delay on detecting dead peers
dead_peer_timeout 5 seconds

# Pipeline prefetch for faster throughput
pipeline_prefetch on

# Half-closed clients — allow them (some sites close one direction early)
half_closed_clients on
SQUIDEOF

    print_success "Configuration written to /etc/squid/squid.conf"
    echo ""
}

#############################################
# Configure Kernel (keep existing + add)
#############################################

configure_kernel() {
    print_separator
    echo -e "${BOLD}Configuring kernel settings...${NC}"
    echo ""

    cat > /etc/sysctl.d/99-squid-proxy.conf <<EOF
# Squid Forward Proxy v2.0 — Kernel Tuning

# File limits
fs.file-max = 2097152

# TCP performance
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2

# TIME-WAIT management
net.ipv4.tcp_max_tw_buckets = 1440000

# Keepalive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# Orphan connection cleanup
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_max_orphans = 16384
net.ipv4.tcp_abort_on_overflow = 1

# Conntrack — generous limits for high concurrency
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10

# Network buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 65535

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

    sysctl -p /etc/sysctl.d/99-squid-proxy.conf > /dev/null 2>&1 || true
    print_success "Kernel settings applied"

    # Clear conntrack table
    conntrack -F > /dev/null 2>&1 || true

    # File limits for squid user
    cat > /etc/security/limits.d/squid.conf <<EOF
*       soft    nofile    100000
*       hard    nofile    100000
proxy   soft    nofile    100000
proxy   hard    nofile    100000
*       soft    nproc     100000
*       hard    nproc     100000
EOF
    print_success "File descriptor limits set"

    echo ""
}

#############################################
# Configure Squid Systemd Override
#############################################

configure_systemd() {
    print_separator
    echo -e "${BOLD}Configuring systemd service...${NC}"
    echo ""

    mkdir -p /etc/systemd/system/squid.service.d

    cat > /etc/systemd/system/squid.service.d/override.conf <<EOF
[Service]
LimitNOFILE=100000
LimitNPROC=100000
Restart=on-failure
RestartSec=5s
EOF

    systemctl daemon-reload
    print_success "Systemd override created (LimitNOFILE=100000)"

    echo ""
}

#############################################
# Configure Firewall
#############################################

configure_firewall() {
    print_separator
    echo -e "${BOLD}Configuring firewall...${NC}"
    echo ""

    if command -v ufw &> /dev/null; then
        ufw allow 22/tcp > /dev/null 2>&1 || true
        ufw allow "$HTTP_PORT/tcp" > /dev/null 2>&1 || true

        if ! ufw status | grep -q "Status: active"; then
            echo "y" | ufw enable > /dev/null 2>&1 || true
        else
            ufw reload > /dev/null 2>&1 || true
        fi

        print_success "UFW: port $HTTP_PORT and SSH opened"
    else
        print_info "UFW not found — ensure port $HTTP_PORT is open in your firewall"
    fi

    echo ""
}

#############################################
# Start and Test
#############################################

start_squid() {
    print_separator
    echo -e "${BOLD}Starting Squid...${NC}"
    echo ""

    # Initialize cache directories (even though we don't cache)
    squid -z --foreground > /dev/null 2>&1 || true

    # Validate config
    echo -n "Validating configuration... "
    if squid -k parse 2>/dev/null; then
        print_success "Config valid"
    else
        # Show errors for debugging
        squid -k parse 2>&1 || true
        error_exit "Invalid Squid configuration"
    fi

    echo -n "Starting squid service... "
    systemctl enable squid > /dev/null 2>&1
    systemctl start squid

    sleep 3

    if systemctl is-active --quiet squid; then
        print_success "Squid is running"
    else
        echo ""
        print_error "Squid failed to start"
        journalctl -u squid -n 30 --no-pager
        error_exit "Check logs above"
    fi

    # Verify listening
    if ss -tlnp | grep -q ":$HTTP_PORT"; then
        print_success "Listening on port $HTTP_PORT"
    else
        print_warning "Port $HTTP_PORT not detected yet — may need a few more seconds"
    fi

    echo ""
}

test_proxy() {
    print_separator
    echo -e "${BOLD}Testing proxy...${NC}"
    echo ""

    sleep 2

    # Test 1: HTTP through proxy
    echo -e "${CYAN}[Test 1: HTTP request through proxy]${NC}"
    HTTP_RESULT=$(curl -s \
        -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" \
        --max-time 15 \
        -w "\n%{http_code}|%{time_total}" \
        "http://ifconfig.me" 2>/dev/null)

    if [ $? -eq 0 ]; then
        HTTP_IP=$(echo "$HTTP_RESULT" | head -n 1)
        HTTP_CODE=$(echo "$HTTP_RESULT" | tail -n 1 | cut -d'|' -f1)
        HTTP_TIME=$(echo "$HTTP_RESULT" | tail -n 1 | cut -d'|' -f2)

        if [ "$HTTP_CODE" = "200" ]; then
            print_success "HTTP proxy working"
            echo "    External IP  : $HTTP_IP"
            echo "    Response time: ${HTTP_TIME}s"
        else
            print_warning "HTTP test returned status $HTTP_CODE"
        fi
    else
        print_warning "HTTP test failed — may need a moment to initialize"
    fi

    echo ""

    # Test 2: HTTPS through proxy (CONNECT tunnel)
    echo -e "${CYAN}[Test 2: HTTPS request through proxy (CONNECT)]${NC}"
    HTTPS_RESULT=$(curl -s \
        -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" \
        --max-time 15 \
        -w "\n%{http_code}|%{time_total}" \
        "https://ifconfig.me" 2>/dev/null)

    if [ $? -eq 0 ]; then
        HTTPS_IP=$(echo "$HTTPS_RESULT" | head -n 1)
        HTTPS_CODE=$(echo "$HTTPS_RESULT" | tail -n 1 | cut -d'|' -f1)
        HTTPS_TIME=$(echo "$HTTPS_RESULT" | tail -n 1 | cut -d'|' -f2)

        if [ "$HTTPS_CODE" = "200" ]; then
            print_success "HTTPS proxy working (CONNECT tunnel)"
            echo "    External IP  : $HTTPS_IP"
            echo "    Response time: ${HTTPS_TIME}s"
        else
            print_warning "HTTPS test returned status $HTTPS_CODE"
        fi
    else
        print_warning "HTTPS test failed"
    fi

    echo ""

    # Test 3: Anonymous check
    echo -e "${CYAN}[Test 3: Anonymous header check]${NC}"
    HEADERS=$(curl -s \
        -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" \
        --max-time 15 \
        "http://httpbin.org/headers" 2>/dev/null)

    if echo "$HEADERS" | grep -qi "X-Forwarded-For"; then
        print_warning "X-Forwarded-For header detected — proxy may not be fully anonymous"
    else
        print_success "Anonymous: No X-Forwarded-For header leaked"
    fi

    if echo "$HEADERS" | grep -qi "Via"; then
        print_warning "Via header detected"
    else
        print_success "Anonymous: No Via header leaked"
    fi

    echo ""
}

#############################################
# Create Monitor Script
#############################################

create_monitor() {
    cat > /root/monitor_squid.sh <<'MONEOF'
#!/bin/bash
echo "╔═════════════════════════════════════════╗"
echo "║   Squid Proxy Monitor v2.0              ║"
echo "║   Forum Registration Checker            ║"
echo "╚═════════════════════════════════════════╝"
echo "Timestamp: $(date)"
echo ""

echo "━━━ Service Status ━━━"
if systemctl is-active --quiet squid; then
    echo "✓ Squid: Running"
    echo "  Uptime: $(systemctl show squid --property=ActiveEnterTimestamp --value)"
else
    echo "✗ Squid: Stopped"
fi
echo ""

echo "━━━ Squid Process Info ━━━"
SQUID_PIDS=$(pgrep -f "squid" | head -20)
SQUID_COUNT=$(echo "$SQUID_PIDS" | wc -l)
SQUID_RSS=$(ps aux | grep "[s]quid" | awk '{sum += $6} END {printf "%.1f", sum/1024}')
echo "  Processes : $SQUID_COUNT (workers + helpers)"
echo "  Total RAM : ${SQUID_RSS} MB"
echo ""

echo "━━━ Memory ━━━"
free -h | head -2
echo ""

echo "━━━ Conntrack ━━━"
CURRENT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
echo "  Usage: $CURRENT / $MAX"
if [ "$MAX" != "N/A" ] && [ "$CURRENT" != "N/A" ]; then
    PCT=$((CURRENT * 100 / MAX))
    echo "  Percent: ${PCT}%"
    if [ "$PCT" -gt 80 ]; then
        echo "  ⚠ WARNING: Conntrack >80%!"
    fi
fi
echo ""

echo "━━━ TCP Connection States ━━━"
ss -ant | awk '{print $1}' | sort | uniq -c | sort -nr
echo ""

echo "━━━ Proxy Port Connections ━━━"
PROXY_CONNS=$(ss -ant | grep ":3128" | grep -c ESTAB 2>/dev/null || echo "0")
echo "  Active connections on :3128 = $PROXY_CONNS"
echo ""

echo "━━━ DNS Test ━━━"
if nslookup google.com 1.1.1.1 > /dev/null 2>&1; then
    echo "  ✓ DNS working"
else
    echo "  ✗ DNS failed"
fi
echo ""

echo "━━━ Squid Service Logs (last 5 lines) ━━━"
tail -5 /var/log/squid/cache.log 2>/dev/null || echo "  No log file found"
echo ""
MONEOF

    chmod +x /root/monitor_squid.sh
    print_success "Monitor script: /root/monitor_squid.sh"
}

#############################################
# Save Details
#############################################

save_details() {
    cat > /root/proxy_details.txt <<EOF
═══════════════════════════════════════════
Squid Forward Proxy v2.0
Forum Registration Checker Edition
═══════════════════════════════════════════

Server IP : $SERVER_IP
Username  : $PROXY_USER
Password  : $PROXY_PASS
Port      : $HTTP_PORT

Connection String:
http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT

═══════════════════════════════════════════

Workers       : $SQUID_WORKERS
Caching       : Disabled
DNS           : 1.1.1.1, 8.8.8.8, 8.8.4.4 (Squid internal resolver)
Anonymous     : Yes (elite — no Via, no X-Forwarded-For)
Conntrack max : 524288

Commands:
  Restart  : systemctl restart squid
  Status   : systemctl status squid
  Logs     : tail -f /var/log/squid/cache.log
  Monitor  : /root/monitor_squid.sh
  Test     : curl -x http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT http://ifconfig.me

Date: $(date)
═══════════════════════════════════════════
EOF

    chmod 600 /root/proxy_details.txt
    print_success "Details saved to /root/proxy_details.txt"
}

#############################################
# Display Results
#############################################

display_results() {
    echo ""
    print_separator
    echo -e "${GREEN}${BOLD}╔═════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       Installation Complete! ✓          ║${NC}"
    echo -e "${GREEN}${BOLD}╚═════════════════════════════════════════╝${NC}"
    print_separator
    echo ""
    echo -e "${BOLD}Proxy Details:${NC}"
    echo ""
    echo -e "  Connection: ${GREEN}http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT${NC}"
    echo ""
    print_separator
    echo ""
    echo -e "${BOLD}What changed vs 3proxy:${NC}"
    echo "  ✓ Multi-process: $SQUID_WORKERS workers (3proxy had 1)"
    echo "  ✓ Async DNS resolver (no OS bottleneck)"
    echo "  ✓ Conntrack: 524288 (was 262144)"
    echo "  ✓ Battle-tested architecture for high concurrency"
    echo "  ✓ Same port ($HTTP_PORT), same credentials — no code changes needed"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  systemctl restart squid       # Restart"
    echo "  systemctl status squid        # Status"
    echo "  /root/monitor_squid.sh        # Live monitoring"
    echo "  tail -f /var/log/squid/cache.log  # Logs"
    echo ""
    print_separator
}

#############################################
# Main
#############################################

main() {
    print_header

    echo "Checking system..."
    check_root
    check_os
    print_success "Running as root"
    echo ""

    detect_network
    get_user_input

    remove_3proxy
    install_squid
    configure_squid
    configure_kernel
    configure_systemd
    configure_firewall
    start_squid
    test_proxy
    create_monitor
    save_details
    display_results
}

main
