#!/usr/bin/env bash

set -euo pipefail

#############################################
# Squid Forward Proxy Setup Script v4.0
# Stable + modern build for forum checker
#
# Key fixes vs v3:
# - Pins Squid to a known-stable release (default: v6.12)
# - half_closed_clients OFF (default, safer for forward proxy)
# - pipeline_prefetch OFF (avoid risky connection behavior)
# - Uses system DNS resolver (no hardcoded public DNS)
# - Adds assert/crash smoke checks after startup
#############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

DEFAULT_PORT=3128
SCRIPT_REV="v4.1.0"
DEFAULT_SQUID_SERIES="v6"
DEFAULT_SQUID_VERSION="6.12"
DEFAULT_SQUID_TARBALL_EXT="xz"
SQUID_PREFIX="/usr/local/squid"
SQUID_ETC_DIR="/etc/squid"
SQUID_LOG_DIR="/var/log/squid"
SQUID_SPOOL_DIR="/var/spool/squid"
SQUID_SRC_DIR="/usr/local/src/squid-build"
SQUID_PASSWD_FILE="/etc/squid/passwd"

SERVER_IP=""
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
HTTP_PORT="${HTTP_PORT:-$DEFAULT_PORT}"
SQUID_WORKERS="1"
RECOMMENDED_CONCURRENCY="80"
BUILD_JOBS="1"
SQUID_VERSION="${SQUID_VERSION:-$DEFAULT_SQUID_VERSION}"
SQUID_SERIES="${SQUID_SERIES:-$DEFAULT_SQUID_SERIES}"
SQUID_TARBALL_EXT="${SQUID_TARBALL_EXT:-$DEFAULT_SQUID_TARBALL_EXT}"
AUTO_YES="${AUTO_YES:-0}"

if [ -t 0 ] && [ -t 1 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    TTY_AVAILABLE=1
else
    TTY_AVAILABLE=0
fi

print_header() {
    if [ "$INTERACTIVE" -eq 1 ]; then
        clear || true
    fi
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo -e "${CYAN}|${NC} ${BOLD}Squid Forward Proxy Setup ${SCRIPT_REV}${NC}             ${CYAN}|${NC}"
    echo -e "${CYAN}|${NC} Pinned Squid ${SQUID_SERIES}/${SQUID_VERSION} hardening       ${CYAN}|${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
}

print_separator() { echo -e "${BLUE}--------------------------------------------------${NC}"; }
print_success()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_error()     { echo -e "${RED}[ERR]${NC} $1"; }
print_warning()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info()      { echo -e "${CYAN}[INFO]${NC} $1"; }

error_exit() {
    print_error "$1"
    exit 1
}

run_step() {
    local step_name="$1"
    shift

    "$@"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        error_exit "Step failed: $step_name (exit $rc)"
    fi
}

prompt_read() {
    local prompt="$1"
    local var_name="$2"

    if [ "$TTY_AVAILABLE" -eq 1 ]; then
        read -r -p "$prompt" "$var_name" < /dev/tty
    else
        read -r -p "$prompt" "$var_name"
    fi
}

prompt_read_silent() {
    local prompt="$1"
    local var_name="$2"

    if [ "$TTY_AVAILABLE" -eq 1 ]; then
        read -r -s -p "$prompt" "$var_name" < /dev/tty
    else
        read -r -s -p "$prompt" "$var_name"
    fi
}

check_root() {
    if [ "${EUID}" -ne 0 ]; then
        error_exit "This script must be run as root. Use: sudo bash $0"
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        CODENAME="${VERSION_CODENAME:-}"
        PRETTY="${PRETTY_NAME:-$ID}"
    else
        error_exit "Cannot detect OS. Supports Debian/Ubuntu only."
    fi

    case "$OS" in
        ubuntu|debian)
            print_success "$PRETTY detected"
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

    SERVER_IP=$(curl -fsS -4 --max-time 10 ifconfig.me 2>/dev/null || \
                curl -fsS -4 --max-time 10 icanhazip.com 2>/dev/null || \
                curl -fsS -4 --max-time 10 ipinfo.io/ip 2>/dev/null || true)

    if [ -z "$SERVER_IP" ]; then
        error_exit "Could not detect public IP address"
    fi

    print_success "Public IP: $SERVER_IP"
    echo ""
}

choose_capacity_defaults() {
    local total_ram_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2; exit}' || true)
    if ! [[ "$total_ram_mb" =~ ^[0-9]+$ ]]; then
        total_ram_mb=1024
    fi

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || true)
    if ! [[ "$cpu_count" =~ ^[0-9]+$ ]]; then
        cpu_count=1
    fi

    if [ "$total_ram_mb" -le 1024 ]; then
        SQUID_WORKERS=1
        RECOMMENDED_CONCURRENCY=80
        BUILD_JOBS=1
    elif [ "$total_ram_mb" -le 2048 ]; then
        SQUID_WORKERS=2
        RECOMMENDED_CONCURRENCY=150
        BUILD_JOBS=1
    elif [ "$total_ram_mb" -le 4096 ]; then
        SQUID_WORKERS=3
        RECOMMENDED_CONCURRENCY=250
        BUILD_JOBS=$(( cpu_count > 2 ? 2 : cpu_count ))
    else
        SQUID_WORKERS=4
        RECOMMENDED_CONCURRENCY=400
        BUILD_JOBS=$(( cpu_count > 4 ? 4 : cpu_count ))
    fi

    if [ "$BUILD_JOBS" -lt 1 ]; then
        BUILD_JOBS=1
    fi

    return 0
}

get_user_input() {
    print_separator
    echo -e "${BOLD}Configuration${NC}"
    echo ""

    if [ -z "$PROXY_USER" ]; then
        if [ "$INTERACTIVE" -eq 1 ]; then
            while true; do
                if ! prompt_read "Proxy username: " PROXY_USER; then
                    error_exit "Input stream closed while reading username"
                fi
                [ -n "$PROXY_USER" ] && break
                print_error "Username cannot be empty"
            done
        else
            error_exit "PROXY_USER is required in non-interactive mode"
        fi
    fi

    if [ -z "$PROXY_PASS" ]; then
        if [ "$INTERACTIVE" -eq 1 ]; then
            while true; do
                if ! prompt_read_silent "Proxy password: " PROXY_PASS; then
                    echo ""
                    error_exit "Input stream closed while reading password"
                fi
                echo ""
                if [ -z "$PROXY_PASS" ]; then
                    print_error "Password cannot be empty"
                    continue
                fi

                local proxy_pass_confirm
                if ! prompt_read_silent "Confirm password: " proxy_pass_confirm; then
                    echo ""
                    error_exit "Input stream closed while confirming password"
                fi
                echo ""

                if [ "$PROXY_PASS" != "$proxy_pass_confirm" ]; then
                    print_error "Passwords do not match"
                else
                    break
                fi
            done
        else
            error_exit "PROXY_PASS is required in non-interactive mode"
        fi
    fi

    if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1024 ] || [ "$HTTP_PORT" -gt 65535 ]; then
        if [ "$INTERACTIVE" -eq 1 ]; then
            while true; do
                if ! prompt_read "HTTP port [$DEFAULT_PORT]: " HTTP_PORT; then
                    error_exit "Input stream closed while reading port"
                fi
                HTTP_PORT=${HTTP_PORT:-$DEFAULT_PORT}
                if [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && [ "$HTTP_PORT" -ge 1024 ] && [ "$HTTP_PORT" -le 65535 ]; then
                    break
                fi
                print_error "Invalid port. Must be 1024-65535"
            done
        else
            error_exit "HTTP_PORT must be a valid integer between 1024-65535"
        fi
    fi

    echo ""
    echo -e "${BOLD}Installation Summary:${NC}"
    echo ""
    echo "  Server IP              : $SERVER_IP"
    echo "  Username               : $PROXY_USER"
    echo "  Password               : ${PROXY_PASS//?/*}"
    echo "  Port                   : $HTTP_PORT"
    echo "  Squid workers          : $SQUID_WORKERS"
    echo "  Build jobs             : $BUILD_JOBS"
    echo "  Pinned Squid release   : ${SQUID_SERIES}/${SQUID_VERSION}.tar.${SQUID_TARBALL_EXT}"
    echo "  Recommended concurrency: $RECOMMENDED_CONCURRENCY"
    echo ""

    if [ "$AUTO_YES" = "1" ]; then
        print_info "AUTO_YES=1 set, proceeding without confirmation"
    elif [ "$INTERACTIVE" -eq 1 ]; then
        if [ "$TTY_AVAILABLE" -eq 1 ]; then
            read -r -p "Proceed? (y/n): " -n 1 REPLY < /dev/tty || {
                echo ""
                error_exit "Input stream closed while waiting for confirmation"
            }
        elif ! read -r -p "Proceed? (y/n): " -n 1 REPLY; then
            echo ""
            error_exit "Input stream closed while waiting for confirmation"
        fi
        echo ""
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi
    else
        error_exit "Non-interactive mode requires AUTO_YES=1"
    fi
    echo ""
}

setup_swap() {
    print_separator
    echo -e "${BOLD}Configuring swap...${NC}"
    echo ""

    if swapon --show | grep -q .; then
        print_success "Swap already exists"
    else
        echo -n "Creating 2GB swap file... "
        if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 > /dev/null 2>&1; then
            chmod 600 /swapfile
            mkswap /swapfile > /dev/null 2>&1
            swapon /swapfile
            grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            print_success "2GB swap enabled"
        else
            print_warning "Swap creation failed; continuing"
        fi
    fi

    sysctl -w vm.swappiness=10 > /dev/null 2>&1 || true
    echo ""
}

install_prerequisites() {
    print_separator
    echo -e "${BOLD}Installing build prerequisites...${NC}"
    echo ""

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential pkg-config perl m4 \
        libssl-dev libexpat1-dev libxml2-dev \
        zlib1g-dev libcppunit-dev libecap3-dev \
        libdb-dev libsasl2-dev libldap2-dev libpam0g-dev \
        apache2-utils ca-certificates curl xz-utils tar \
        ufw conntrack

    print_success "Dependencies installed"
    echo ""
}

stop_old_squid() {
    print_separator
    echo -e "${BOLD}Stopping old proxy services...${NC}"
    echo ""

    systemctl stop squid > /dev/null 2>&1 || true
    systemctl disable squid > /dev/null 2>&1 || true
    pkill -9 squid > /dev/null 2>&1 || true

    print_success "Old squid processes stopped"
    echo ""
}

validate_pinned_release() {
    if [ -z "$SQUID_SERIES" ] || [ -z "$SQUID_VERSION" ] || [ -z "$SQUID_TARBALL_EXT" ]; then
        error_exit "Invalid Squid pin configuration"
    fi

    local test_url
    test_url="https://www.squid-cache.org/Versions/${SQUID_SERIES}/squid-${SQUID_VERSION}.tar.${SQUID_TARBALL_EXT}"

    if ! curl -fsI "$test_url" > /dev/null; then
        error_exit "Pinned Squid tarball not found: $test_url"
    fi
}

build_squid() {
    print_separator
    echo -e "${BOLD}Building Squid from source...${NC}"
    echo ""

    validate_pinned_release
    print_info "Using pinned Squid release: $SQUID_VERSION ($SQUID_SERIES, tar.$SQUID_TARBALL_EXT)"

    mkdir -p "$SQUID_SRC_DIR"
    rm -rf "$SQUID_SRC_DIR"/*

    local tarball="squid-${SQUID_VERSION}.tar.${SQUID_TARBALL_EXT}"
    local url="https://www.squid-cache.org/Versions/${SQUID_SERIES}/${tarball}"

    echo -n "Downloading ${tarball}... "
    curl -fsSL "$url" -o "$SQUID_SRC_DIR/$tarball"
    print_success "Done"

    tar -xf "$SQUID_SRC_DIR/$tarball" -C "$SQUID_SRC_DIR"
    cd "$SQUID_SRC_DIR/squid-${SQUID_VERSION}"

    echo -n "Configuring build... "
    ./configure \
        --prefix="$SQUID_PREFIX" \
        --sysconfdir="$SQUID_ETC_DIR" \
        --localstatedir=/var \
        --libexecdir="$SQUID_PREFIX/libexec" \
        --with-default-user=proxy \
        --with-openssl \
        --enable-auth-basic=NCSA \
        --disable-translation \
        --with-filedescriptors=100000 \
        > /tmp/squid-configure.log 2>&1 || {
        print_error "Configure failed. See /tmp/squid-configure.log"
        exit 1
    }
    print_success "Done"

    echo -n "Compiling (jobs=$BUILD_JOBS)... "
    make -j"$BUILD_JOBS" > /tmp/squid-build.log 2>&1 || {
        print_error "Build failed. See /tmp/squid-build.log"
        exit 1
    }
    print_success "Done"

    echo -n "Installing... "
    make install > /tmp/squid-install.log 2>&1 || {
        print_error "Install failed. See /tmp/squid-install.log"
        exit 1
    }
    print_success "Done"

    print_success "Installed Squid ${SQUID_VERSION} at ${SQUID_PREFIX}"
    echo ""
}

prepare_runtime() {
    print_separator
    echo -e "${BOLD}Preparing runtime directories and auth...${NC}"
    echo ""

    getent group proxy >/dev/null 2>&1 || groupadd --system proxy
    id -u proxy >/dev/null 2>&1 || useradd --system --gid proxy --home-dir /nonexistent --shell /usr/sbin/nologin proxy

    mkdir -p "$SQUID_ETC_DIR" "$SQUID_LOG_DIR" "$SQUID_SPOOL_DIR" /run/squid
    chown -R proxy:proxy "$SQUID_LOG_DIR" "$SQUID_SPOOL_DIR" /run/squid

    htpasswd -cb "$SQUID_PASSWD_FILE" "$PROXY_USER" "$PROXY_PASS" > /dev/null 2>&1
    chmod 640 "$SQUID_PASSWD_FILE"
    chown root:proxy "$SQUID_PASSWD_FILE" || true

    print_success "Runtime directories and credentials prepared"
    echo ""
}

write_squid_config() {
    print_separator
    echo -e "${BOLD}Writing squid.conf (stable forward-proxy profile)...${NC}"
    echo ""

    cat > "$SQUID_ETC_DIR/squid.conf" <<EOF
# Squid Forward Proxy v4.0
# Focus: stability under high CONNECT concurrency

workers $SQUID_WORKERS
max_filedescriptors 100000

http_port $HTTP_PORT
pid_filename /run/squid/squid.pid
coredump_dir $SQUID_SPOOL_DIR

# Authentication
auth_param basic program $SQUID_PREFIX/libexec/basic_ncsa_auth $SQUID_PASSWD_FILE
auth_param basic children 64 startup=16 idle=8
auth_param basic realm ForumCheckerProxy
auth_param basic credentialsttl 24 hours
acl authenticated proxy_auth REQUIRED

# Access rules
acl SSL_ports port 1-65535
acl Safe_ports port 1-65535
acl CONNECT method CONNECT

http_access allow CONNECT authenticated
http_access allow authenticated
http_access deny all

# Privacy / anonymity
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

# No caching (checker workload)
cache deny all
cache_mem 16 MB
maximum_object_size 0 KB
memory_pools off

# Logs
access_log none
cache_store_log none
cache_log $SQUID_LOG_DIR/cache.log

# Connection behavior tuned for forward proxy stability
connect_timeout 20 seconds
read_timeout 45 seconds
request_timeout 45 seconds
client_idle_pconn_timeout 20 seconds
pconn_timeout 10 seconds
forward_timeout 30 seconds
shutdown_lifetime 3 seconds

# Important stability defaults (v3 bugfix)
half_closed_clients off
pipeline_prefetch off

httpd_suppress_version_string on
icp_port 0
dead_peer_timeout 5 seconds
EOF

    print_success "squid.conf written"
    echo ""
}

write_sysctl_profile() {
    print_separator
    echo -e "${BOLD}Applying kernel tuning (safe profile)...${NC}"
    echo ""

    cat > /etc/sysctl.d/99-squid-proxy-v4.conf <<'EOF'
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.netfilter.nf_conntrack_max = 262144
vm.swappiness = 10
EOF

    sysctl --system > /dev/null 2>&1 || true
    conntrack -F > /dev/null 2>&1 || true

    cat > /etc/security/limits.d/squid-v4.conf <<'EOF'
*       soft    nofile    100000
*       hard    nofile    100000
proxy   soft    nofile    100000
proxy   hard    nofile    100000
EOF

    print_success "Kernel + limits profile applied"
    echo ""
}

write_systemd_unit() {
    print_separator
    echo -e "${BOLD}Creating systemd unit...${NC}"
    echo ""

    cat > /etc/systemd/system/squid.service <<EOF
[Unit]
Description=Squid Web Proxy Server (custom v4)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=proxy
Group=proxy
PIDFile=/run/squid/squid.pid
RuntimeDirectory=squid
RuntimeDirectoryMode=0755
ExecStartPre=$SQUID_PREFIX/sbin/squid -k parse -f $SQUID_ETC_DIR/squid.conf
ExecStart=$SQUID_PREFIX/sbin/squid -f $SQUID_ETC_DIR/squid.conf
ExecReload=$SQUID_PREFIX/sbin/squid -k reconfigure -f $SQUID_ETC_DIR/squid.conf
ExecStop=$SQUID_PREFIX/sbin/squid -k shutdown -f $SQUID_ETC_DIR/squid.conf
LimitNOFILE=100000
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "systemd unit created"
    echo ""
}

configure_firewall() {
    print_separator
    echo -e "${BOLD}Configuring firewall...${NC}"
    echo ""

    if command -v ufw > /dev/null 2>&1; then
        ufw allow 22/tcp > /dev/null 2>&1 || true
        ufw allow "$HTTP_PORT/tcp" > /dev/null 2>&1 || true

        if ! ufw status | grep -q "Status: active"; then
            echo "y" | ufw enable > /dev/null 2>&1 || true
        else
            ufw reload > /dev/null 2>&1 || true
        fi
        print_success "UFW updated (SSH + $HTTP_PORT)"
    else
        print_info "UFW not installed; open TCP/$HTTP_PORT in your cloud firewall"
    fi

    echo ""
}

start_and_validate() {
    print_separator
    echo -e "${BOLD}Starting and validating Squid...${NC}"
    echo ""

    systemctl enable squid > /dev/null 2>&1
    systemctl restart squid
    sleep 3

    if ! systemctl is-active --quiet squid; then
        journalctl -u squid -n 80 --no-pager || true
        error_exit "Squid failed to start"
    fi

    print_success "Squid is running"

    local local_url="http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT"
    local ok=0
    for i in $(seq 1 5); do
        if curl -s -o /dev/null -x "$local_url" --max-time 15 https://example.com; then
            ok=$((ok+1))
        fi
    done

    if [ "$ok" -lt 3 ]; then
        print_warning "Proxy test passed only $ok/5 times"
    else
        print_success "Proxy test passed $ok/5"
    fi

    # Quick assert smoke check
    if journalctl -u squid -n 200 --no-pager | grep -q "assertion failed"; then
        print_warning "Assertion detected in startup logs. Check: journalctl -u squid -n 300"
    else
        print_success "No assertion detected in startup logs"
    fi

    echo ""
}

create_monitor_script() {
    cat > /root/monitor_squid_v4.sh <<'EOF'
#!/usr/bin/env bash
set -u

PORT="${1:-3128}"

echo "Timestamp: $(date)"
echo ""
echo "Service:"
systemctl is-active squid || true
echo ""
echo "Workers:"
ps -eo pid,ppid,%cpu,%mem,rss,etime,cmd | grep '[s]quid' || true
echo ""
echo "Socket states on :$PORT"
ss -ant "( sport = :$PORT or dport = :$PORT )" | awk 'NR>1{c[$1]++} END{for (s in c) print s, c[s]}'
echo ""
echo "Kernel conntrack:"
echo -n "count="; cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || true
echo -n "max="; cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
echo ""
echo "Recent squid assertions:"
journalctl -u squid -n 200 --no-pager | grep -E "assertion failed|will not be restarted" || echo "none"
echo ""
echo "Cache log tail:"
tail -n 20 /var/log/squid/cache.log 2>/dev/null || true
EOF

    chmod +x /root/monitor_squid_v4.sh
}

save_details() {
    cat > /root/proxy_details.txt <<EOF
Squid Forward Proxy v4.0
========================

Squid version: $SQUID_VERSION
Server IP    : $SERVER_IP
Port         : $HTTP_PORT
Username     : $PROXY_USER
Password     : $PROXY_PASS

Connection:
http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT

Stability profile:
- half_closed_clients off
- pipeline_prefetch off
- no hardcoded public DNS

Recommended checker settings:
- concurrency: $RECOMMENDED_CONCURRENCY
- request_timeout_secs: 30
- connect_timeout_secs: 15

Useful commands:
- systemctl restart squid
- systemctl status squid
- journalctl -u squid -n 200 --no-pager
- /root/monitor_squid_v4.sh $HTTP_PORT

Generated: $(date)
EOF

    chmod 600 /root/proxy_details.txt
}

display_results() {
    print_separator
    echo -e "${GREEN}${BOLD}Installation Complete${NC}"
    print_separator
    echo ""
    echo "Connection: http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT"
    echo "Squid version: $SQUID_VERSION"
    echo "Monitor script: /root/monitor_squid_v4.sh"
    echo "Details file : /root/proxy_details.txt"
    echo ""
}

main() {
    run_step "print_header" print_header
    run_step "check_root" check_root
    run_step "check_os" check_os
    run_step "detect_network" detect_network
    run_step "choose_capacity_defaults" choose_capacity_defaults
    run_step "get_user_input" get_user_input
    run_step "setup_swap" setup_swap
    run_step "install_prerequisites" install_prerequisites
    run_step "stop_old_squid" stop_old_squid
    run_step "build_squid" build_squid
    run_step "prepare_runtime" prepare_runtime
    run_step "write_squid_config" write_squid_config
    run_step "write_sysctl_profile" write_sysctl_profile
    run_step "write_systemd_unit" write_systemd_unit
    run_step "configure_firewall" configure_firewall
    run_step "start_and_validate" start_and_validate
    run_step "create_monitor_script" create_monitor_script
    run_step "save_details" save_details
    run_step "display_results" display_results
}

main "$@"
