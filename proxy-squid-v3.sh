#!/bin/bash

#############################################
# Squid Forward Proxy Setup Script v3.0
# forum-registration-checker optimized
#
# v3.0 değişiklikleri (v2.0'dan farklar):
# - 2GB Swap eklendi (OOM kill koruması)
# - workers: RAM'e göre dinamik (min 3, max 8)
# - auth_param children: 10 → 20 (concurrent auth bottleneck giderildi)
# - cache_mem: 8MB → 4MB (caching zaten kapalı, küçük RAM tasarrufu)
# - RAM tabanlı worker hesaplaması iyileştirildi
#
# Korunananlar:
# - Port 3128 (Rust programında değişiklik yok)
# - Aynı credential formatı
# - Tüm timeout değerleri (test analizinde sorun çıkarmadı)
# - Anonymization/elite proxy ayarları
# - Conntrack 524288
#
# RAM → Workers tablosu:
#   ≤1GB  → 3 workers  (~100MB/worker, ~300MB toplam)
#   ≤2GB  → 4 workers
#   ≤4GB  → 6 workers
#   >4GB  → 8 workers
#
# Kullanım: sudo bash proxy-squid-v3.sh
#############################################

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
    echo -e "${CYAN}║${NC}  ${BOLD}Squid Forward Proxy Setup v3.0${NC}         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  forum-registration-checker optimized   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  RAM-aware workers + Swap + Auth fix    ${CYAN}║${NC}"
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

    # ── RAM-aware worker calculation ──────────────────────────────
    # Squid no-cache mode: ~80-120MB per worker under load.
    # We leave at least 300MB headroom for OS + other processes.
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    AVAILABLE_RAM_MB=$(free -m | awk '/^Mem:/{print $7}')

    if [ "$TOTAL_RAM_MB" -le 1024 ]; then
        # ≤1GB: 3 workers minimum.
        # v2.0 had 2 — bumped to 3 because idle available RAM supports it
        # and c=200+ "connection closed" errors were traced to worker saturation.
        SQUID_WORKERS=3
        RECOMMENDED_CONCURRENCY=200
    elif [ "$TOTAL_RAM_MB" -le 2048 ]; then
        SQUID_WORKERS=4
        RECOMMENDED_CONCURRENCY=400
    elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
        SQUID_WORKERS=6
        RECOMMENDED_CONCURRENCY=600
    else
        SQUID_WORKERS=8
        RECOMMENDED_CONCURRENCY=1000
    fi

    echo ""
    echo -e "${BOLD}Installation Summary:${NC}"
    echo ""
    echo "  Server IP              : $SERVER_IP"
    echo "  Username               : $PROXY_USER"
    echo "  Password               : ${PROXY_PASS//?/*}"
    echo "  Port                   : $HTTP_PORT"
    echo "  Total RAM              : ${TOTAL_RAM_MB}MB"
    echo "  Available RAM (now)    : ${AVAILABLE_RAM_MB}MB"
    echo "  Squid workers          : $SQUID_WORKERS (v2.0 had $([ "$TOTAL_RAM_MB" -le 1024 ] && echo 2 || echo 'same'))"
    echo "  Auth children          : 20 (v2.0 had 10)"
    echo "  Swap                   : 2GB will be created (v2.0 had none)"
    echo "  Caching                : Disabled"
    echo "  DNS                    : 1.1.1.1, 8.8.8.8, 8.8.4.4"
    echo "  Anonymous              : Yes (elite proxy)"
    echo "  Recommended concurrency: --concurrency $RECOMMENDED_CONCURRENCY"
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
# Setup Swap (NEW in v3.0)
#############################################

setup_swap() {
    print_separator
    echo -e "${BOLD}Configuring Swap...${NC}"
    echo ""

    if swapon --show | grep -q .; then
        print_success "Swap already exists — skipping"
        swapon --show
    else
        echo -n "Creating 2GB swap file... "
        if fallocate -l 2G /swapfile 2>/dev/null || \
           dd if=/dev/zero of=/swapfile bs=1M count=2048 > /dev/null 2>&1; then
            chmod 600 /swapfile
            mkswap /swapfile > /dev/null 2>&1
            swapon /swapfile
            # Persist across reboots
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            print_success "2GB swap created and activated"
            print_info "OOM kill protection enabled — RAM overflow uses disk instead of killing workers"
        else
            print_warning "Failed to create swap file — continuing without swap"
        fi
    fi

    # Reduce swappiness: only use swap when RAM is nearly full
    sysctl -w vm.swappiness=10 > /dev/null 2>&1 || true

    echo ""
}

#############################################
# Remove old proxy installations
#############################################

remove_old_proxies() {
    print_separator
    echo -e "${BOLD}Removing old proxy installations...${NC}"
    echo ""

    # Remove 3proxy
    if systemctl list-units --full -all 2>/dev/null | grep -q "3proxy"; then
        systemctl stop 3proxy > /dev/null 2>&1 || true
        systemctl disable 3proxy > /dev/null 2>&1 || true
        print_success "3proxy service stopped and disabled"
    fi
    pkill -9 3proxy > /dev/null 2>&1 || true
    if [ -d /etc/3proxy ]; then
        cp /etc/3proxy/3proxy.cfg /root/3proxy.cfg.backup 2>/dev/null || true
        rm -rf /etc/3proxy
        print_success "3proxy removed (config backed up to /root/3proxy.cfg.backup)"
    fi
    rm -f /etc/systemd/system/3proxy.service
    rm -rf /etc/systemd/system/3proxy.service.d

    # Stop existing squid before reconfiguring
    if systemctl list-units --full -all 2>/dev/null | grep -q "squid"; then
        systemctl stop squid > /dev/null 2>&1 || true
        print_success "Existing Squid stopped for reconfiguration"
    fi

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

    echo -n "Installing squid + apache2-utils + conntrack... "
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq squid apache2-utils conntrack > /dev/null 2>&1
    print_success "Installed"

    systemctl stop squid > /dev/null 2>&1 || true

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
        error_exit "Could not find basic_ncsa_auth helper"
    fi

    print_success "Auth helper: $NCSA_AUTH"
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
    chown root:proxy /etc/squid/passwd 2>/dev/null || \
    chown root:squid /etc/squid/passwd 2>/dev/null || true
    print_success "Credentials created"

    # Backup original config
    if [ -f /etc/squid/squid.conf ]; then
        cp /etc/squid/squid.conf /etc/squid/squid.conf.v2-backup
        print_success "Previous config backed up to squid.conf.v2-backup"
    fi

    echo -n "Writing Squid v3.0 configuration... "

    cat > /etc/squid/squid.conf <<SQUIDEOF
# ══════════════════════════════════════════════════════════════════
# Squid Forward Proxy v3.0 — Forum Registration Checker
# ══════════════════════════════════════════════════════════════════
# Optimized for: 10M+ domain checking at high concurrency
# Mode: Forward proxy, no caching, anonymous/elite headers
#
# v3.0 changes vs v2.0:
#   - workers: 2 → $SQUID_WORKERS (RAM-aware, min 3 for ≤1GB)
#   - auth_param children: 10 → 20 (fixes auth bottleneck at c=500)
#   - cache_mem: 8MB → 4MB (caching off anyway, small RAM saving)
# ══════════════════════════════════════════════════════════════════

# ── Workers ──────────────────────────────────────────────────────
# Multi-process. Each worker is independent — no shared bottleneck.
# v2.0 used 2 workers. On ≤1GB RAM this caused "connection closed"
# errors at c=200+ (worker saturation). Bumped to 3 minimum.
workers $SQUID_WORKERS

# ── Port ─────────────────────────────────────────────────────────
http_port $HTTP_PORT

# ── DNS ──────────────────────────────────────────────────────────
# Squid's internal async DNS resolver — no OS resolver bottleneck.
dns_nameservers 1.1.1.1 8.8.8.8 8.8.4.4
dns_timeout 15 seconds
positive_dns_ttl 1 hours
negative_dns_ttl 30 seconds

# ── No Caching ───────────────────────────────────────────────────
# Each domain visited once — caching wastes RAM for this workload.
cache deny all
cache_mem 4 MB
maximum_object_size 0 bytes
memory_pools off

# ── File Descriptors ─────────────────────────────────────────────
max_filedescriptors 100000

# ── Timeouts ─────────────────────────────────────────────────────
# Rust client settings.toml:
#   connect_timeout_secs = 20  →  Squid connect_timeout = 30s (margin)
#   request_timeout_secs = 30  →  Squid read_timeout = 60s (generous)
#
# Unchanged from v2.0 — test analysis showed timeouts were from
# slow/dead target sites, not from these settings.

connect_timeout 30 seconds
read_timeout 60 seconds
request_timeout 60 seconds
client_idle_pconn_timeout 30 seconds
pconn_timeout 15 seconds
forward_timeout 30 seconds
shutdown_lifetime 5 seconds

# ── Anonymous / Elite Proxy ──────────────────────────────────────
via off
forwarded_for delete

request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Forwarded deny all
request_header_access X-Real-IP deny all
request_header_access Proxy-Connection deny all

reply_header_access X-Squid-Error deny all
reply_header_access X-Cache deny all
reply_header_access X-Cache-Lookup deny all

# ── Access Control ───────────────────────────────────────────────
# Allow all ports — some forums run on non-standard ports
acl SSL_ports port 1-65535
acl Safe_ports port 1-65535
acl CONNECT method CONNECT

# ── Authentication ───────────────────────────────────────────────
auth_param basic program $NCSA_AUTH /etc/squid/passwd
# v3.0: children bumped from 10 → 20.
# At c=500, each new connection triggers an auth check.
# With 10 children, auth requests queue up and add latency.
# credentialsttl=24h means existing connections skip re-auth,
# but the initial burst at startup needed more helpers.
auth_param basic children 20 startup=5 idle=3
auth_param basic realm ForumCheckerProxy
auth_param basic credentialsttl 24 hours
acl authenticated proxy_auth REQUIRED

# ── Rules ────────────────────────────────────────────────────────
http_access allow CONNECT authenticated
http_access allow authenticated
http_access deny all

# ── Logging ──────────────────────────────────────────────────────
# Disabled — saves disk I/O during 10M domain scan.
access_log none
cache_store_log none
cache_log /var/log/squid/cache.log

httpd_suppress_version_string on

# ── Performance ──────────────────────────────────────────────────
icp_port 0
dead_peer_timeout 5 seconds
pipeline_prefetch on
half_closed_clients on
SQUIDEOF

    print_success "Configuration written"
    echo ""
}

#############################################
# Configure Kernel
#############################################

configure_kernel() {
    print_separator
    echo -e "${BOLD}Configuring kernel settings...${NC}"
    echo ""

    cat > /etc/sysctl.d/99-squid-proxy.conf <<EOF
# Squid Forward Proxy v3.0 — Kernel Tuning
# forum-registration-checker optimized

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
# concurrent * 4 bağlantı (pass1 + homepage + retry + margin)
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

# Swap: only use when RAM is nearly full (v3.0)
vm.swappiness = 10

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

    sysctl -p /etc/sysctl.d/99-squid-proxy.conf > /dev/null 2>&1 || true
    print_success "Kernel settings applied"

    conntrack -F > /dev/null 2>&1 || true
    print_success "Conntrack table cleared"

    cat > /etc/security/limits.d/squid.conf <<EOF
*       soft    nofile    100000
*       hard    nofile    100000
proxy   soft    nofile    100000
proxy   hard    nofile    100000
*       soft    nproc     100000
*       hard    nproc     100000
EOF
    print_success "File descriptor limits set (100000)"

    echo ""
}

#############################################
# Configure Systemd
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
    print_success "Systemd override created (LimitNOFILE=100000, auto-restart)"

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

    squid -z --foreground > /dev/null 2>&1 || true

    echo -n "Validating configuration... "
    if squid -k parse > /dev/null 2>&1; then
        print_success "Config valid"
    else
        squid -k parse 2>&1 || true
        error_exit "Invalid Squid configuration — check output above"
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
        print_warning "HTTP test failed — proxy may need a moment to initialize"
    fi

    echo ""

    echo -e "${CYAN}[Test 2: HTTPS CONNECT tunnel]${NC}"
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

    echo -e "${CYAN}[Test 3: Anonymous header check]${NC}"
    HEADERS=$(curl -s \
        -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" \
        --max-time 15 \
        "http://httpbin.org/headers" 2>/dev/null)

    if echo "$HEADERS" | grep -qi "X-Forwarded-For"; then
        print_warning "X-Forwarded-For header detected"
    else
        print_success "Anonymous: No X-Forwarded-For leaked"
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
echo "║   Squid Proxy Monitor v3.0              ║"
echo "║   Forum Registration Checker            ║"
echo "╚═════════════════════════════════════════╝"
echo "Timestamp: $(date)"
echo ""

echo "━━━ Service Status ━━━"
if systemctl is-active --quiet squid; then
    echo "✓ Squid: Running"
    echo "  Since: $(systemctl show squid --property=ActiveEnterTimestamp --value)"
else
    echo "✗ Squid: Stopped"
fi
echo ""

echo "━━━ Squid Workers ━━━"
SQUID_WORKERS_RUNNING=$(ps aux | grep "[s]quid" | grep -v "grep\|Dead" | wc -l)
SQUID_RSS=$(ps aux | grep "[s]quid" | awk '{sum += $6} END {printf "%.1f", sum/1024}')
echo "  Running processes : $SQUID_WORKERS_RUNNING"
echo "  Total RAM         : ${SQUID_RSS} MB"
echo ""

echo "━━━ Memory ━━━"
free -h | head -2
echo ""

echo "━━━ Swap ━━━"
if swapon --show | grep -q .; then
    swapon --show
else
    echo "  ⚠ No swap configured!"
fi
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
PROXY_PORT=$(grep "^http_port" /etc/squid/squid.conf | awk '{print $2}')
PROXY_CONNS=$(ss -ant | grep ":${PROXY_PORT}" | grep -c ESTAB 2>/dev/null || echo "0")
echo "  Active on :${PROXY_PORT} = $PROXY_CONNS"
echo ""

echo "━━━ DNS Test ━━━"
if nslookup google.com 1.1.1.1 > /dev/null 2>&1; then
    echo "  ✓ DNS working"
else
    echo "  ✗ DNS failed"
fi
echo ""

echo "━━━ Squid Cache Log (last 5) ━━━"
tail -5 /var/log/squid/cache.log 2>/dev/null || echo "  No log"
echo ""
MONEOF

    chmod +x /root/monitor_squid.sh
    print_success "Monitor: /root/monitor_squid.sh"
}

#############################################
# Save Details
#############################################

save_details() {
    cat > /root/proxy_details.txt <<EOF
═══════════════════════════════════════════
Squid Forward Proxy v3.0
Forum Registration Checker Edition
═══════════════════════════════════════════

Server IP  : $SERVER_IP
Username   : $PROXY_USER
Password   : $PROXY_PASS
Port       : $HTTP_PORT

Connection String:
http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT

═══════════════════════════════════════════

Workers       : $SQUID_WORKERS
Auth children : 20
Swap          : 2GB
Caching       : Disabled
DNS           : 1.1.1.1, 8.8.8.8, 8.8.4.4
Anonymous     : Yes (elite)
Conntrack max : 524288
Recommended   : --concurrency $RECOMMENDED_CONCURRENCY

v3.0 improvements over v2.0:
  ✓ workers $SQUID_WORKERS (was 2) — fewer "connection closed" errors at c=200+
  ✓ auth children 20 (was 10) — no auth queue at c=500 burst
  ✓ 2GB swap — OOM kill protection (was missing in v2.0)
  ✓ vm.swappiness=10 — swap used only as last resort

Commands:
  Restart  : systemctl restart squid
  Status   : systemctl status squid
  Logs     : tail -f /var/log/squid/cache.log
  Monitor  : /root/monitor_squid.sh
  Test     : curl -x http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT http://ifconfig.me

Rust program:
  --concurrency $RECOMMENDED_CONCURRENCY  (recommended for this server)

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
    echo -e "${BOLD}v3.0 improvements:${NC}"
    echo "  ✓ workers $SQUID_WORKERS (was 2) — less connection saturation at c=200+"
    echo "  ✓ auth children 20 (was 10) — no auth bottleneck at c=500 burst"
    echo "  ✓ 2GB swap — OOM kill protection (was missing in v2.0)"
    echo "  ✓ vm.swappiness=10 — swap used only as last resort"
    echo ""
    echo -e "${BOLD}Rust program command:${NC}"
    echo "  ./target/release/reg-checker \\"
    echo "    --input-db ../input.db \\"
    echo "    --output-db ../results_full.db \\"
    echo "    --concurrency $RECOMMENDED_CONCURRENCY"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  systemctl restart squid           # Restart"
    echo "  systemctl status squid            # Status"
    echo "  /root/monitor_squid.sh            # Live monitoring"
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

    setup_swap
    remove_old_proxies
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
