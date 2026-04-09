#!/usr/bin/env bash

set -euo pipefail

#############################################
# Squid Forward Proxy Setup Script v4.2.0
# Stable + apt-based install for Ubuntu 24.04
#
# Key fixes vs v4.1:
# - Ubuntu 24.04: installs Squid 6 via apt (no compile, ~2 min vs 15 min)
# - Older Ubuntu/Debian: falls back to source compile
# - Configures public DNS (1.1.1.1 8.8.8.8) via systemd-resolved or
#   /etc/resolv.conf for reliable forum hostname resolution
# - dns_nameservers directive in squid.conf
# - half_closed_clients OFF (default, safer for forward proxy)
# - pipeline_prefetch OFF (avoid risky connection behavior)
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
SCRIPT_REV="v4.2.0"
DEFAULT_SQUID_SERIES="v6"
DEFAULT_SQUID_VERSION="6.12"
DEFAULT_SQUID_TARBALL_EXT="xz"
SQUID_PREFIX="/usr/local/squid"
SQUID_LIBEXEC="/usr/local/squid/libexec"   # overridden by apt path
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
AUTH_CHILDREN="20 startup=10 idle=5"
SQUID_VERSION="${SQUID_VERSION:-$DEFAULT_SQUID_VERSION}"
SQUID_SERIES="${SQUID_SERIES:-$DEFAULT_SQUID_SERIES}"
SQUID_TARBALL_EXT="${SQUID_TARBALL_EXT:-$DEFAULT_SQUID_TARBALL_EXT}"
AUTO_YES="${AUTO_YES:-0}"
TARGET_NF_CONNTRACK_MAX="262144"

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

run_logged_command() {
    local label="$1"
    local logfile="$2"
    shift 2

    : > "$logfile"
    "$@" > "$logfile" 2>&1 &
    local cmd_pid=$!
    local start_ts=$SECONDS
    local last_size=0

    while kill -0 "$cmd_pid" 2>/dev/null; do
        sleep 15

        local elapsed=$(( SECONDS - start_ts ))
        local current_size=0
        if [ -f "$logfile" ]; then
            current_size=$(wc -c < "$logfile" 2>/dev/null || printf '0')
        fi

        if [ "$current_size" -gt "$last_size" ]; then
            printf "\r%s... %ss elapsed, build log growing (%s bytes)" "$label" "$elapsed" "$current_size"
            last_size=$current_size
        else
            printf "\r%s... %ss elapsed, still running               " "$label" "$elapsed"
        fi
    done

    wait "$cmd_pid"
    local rc=$?
    local total_elapsed=$(( SECONDS - start_ts ))
    printf "\r"

    if [ "$rc" -ne 0 ]; then
        print_error "$label failed after ${total_elapsed}s. See $logfile"
        echo ""
        echo "Last 40 log lines:"
        tail -n 40 "$logfile" || true
        return "$rc"
    fi

    print_success "Done (${total_elapsed}s)"
}

read_proc_value() {
    local path="$1"

    if [ -r "$path" ]; then
        tr -d '[:space:]' < "$path"
        return 0
    fi

    return 1
}

verify_conntrack_tuning() {
    local current_max
    local current_count
    local current_buckets

    current_max=$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_max || true)
    current_count=$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_count || true)
    current_buckets=$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_buckets || true)

    if ! [[ "$current_max" =~ ^[0-9]+$ ]]; then
        error_exit "Could not read live nf_conntrack_max after sysctl apply"
    fi

    print_info "Live conntrack values: max=$current_max count=${current_count:-unknown} buckets=${current_buckets:-unknown}"

    if [ "$current_max" -lt "$TARGET_NF_CONNTRACK_MAX" ]; then
        error_exit "nf_conntrack_max stayed at $current_max (expected at least $TARGET_NF_CONNTRACK_MAX). Check sysctl output above."
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

generate_hex_token() {
    local bytes="$1"

    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex "$bytes"
        return 0
    fi

    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

ensure_proxy_credentials() {
    if [ -z "$PROXY_USER" ]; then
        PROXY_USER="u$(generate_hex_token 4)"
        print_info "Generated proxy username automatically"
    fi

    if [ -z "$PROXY_PASS" ]; then
        PROXY_PASS="$(generate_hex_token 24)"
        print_info "Generated strong proxy password automatically"
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
        AUTH_CHILDREN="20 startup=10 idle=5"
    elif [ "$total_ram_mb" -le 2048 ]; then
        SQUID_WORKERS=2
        RECOMMENDED_CONCURRENCY=150
        BUILD_JOBS=1
        AUTH_CHILDREN="16 startup=4 idle=2"
    elif [ "$total_ram_mb" -le 4096 ]; then
        SQUID_WORKERS=3
        RECOMMENDED_CONCURRENCY=250
        BUILD_JOBS=$(( cpu_count > 2 ? 2 : cpu_count ))
        AUTH_CHILDREN="32 startup=8 idle=4"
    else
        SQUID_WORKERS=4
        RECOMMENDED_CONCURRENCY=400
        BUILD_JOBS=$(( cpu_count > 4 ? 4 : cpu_count ))
        AUTH_CHILDREN="64 startup=16 idle=8"
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

    ensure_proxy_credentials

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
    echo "  Password               : auto-generated"
    echo "  Port                   : $HTTP_PORT"
    echo "  Squid workers          : $SQUID_WORKERS"
    echo "  Auth children          : $AUTH_CHILDREN"
    if can_use_apt_squid6; then
        echo "  Install method         : apt (Ubuntu 24.04 fast path, ~2 min)"
        echo "  Squid version          : 6 (latest from apt)"
    else
        echo "  Install method         : source compile (~10-15 min)"
        echo "  Pinned Squid release   : ${SQUID_SERIES}/${SQUID_VERSION}.tar.${SQUID_TARBALL_EXT}"
        echo "  Build jobs             : $BUILD_JOBS"
    fi
    echo "  DNS                    : 1.1.1.1 8.8.8.8 8.8.4.4"
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
    echo -e "${BOLD}Installing base prerequisites...${NC}"
    echo ""

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apache2-utils ca-certificates curl openssl \
        ufw conntrack libjemalloc2

    print_success "Base prerequisites installed"
    echo ""
}

# Returns 0 if we can use apt-based Squid 6 (Ubuntu 24.04+), 1 otherwise
can_use_apt_squid6() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        local _id="${ID:-}"
        local _ver="${VERSION_ID:-}"
        if [ "$_id" = "ubuntu" ] && [ "${_ver%%.*}" -ge 24 ] 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

install_squid_apt() {
    print_separator
    echo -e "${BOLD}Installing Squid 6 via apt (Ubuntu 24.04)...${NC}"
    echo ""

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq squid

    # Resolve the actual binary location — apt may put it at /usr/sbin/squid
    local squid_bin
    squid_bin=$(command -v squid 2>/dev/null || true)
    if [ -z "$squid_bin" ]; then
        error_exit "squid binary not found after apt install"
    fi

    local squid_ver
    squid_ver=$("$squid_bin" -v 2>&1 | head -1 || true)
    print_success "Installed: $squid_ver"
    print_info "Binary: $squid_bin"

    # Point SQUID_PREFIX paths to where apt installed things
    # apt installs to /usr/sbin/squid, libexec at /usr/lib/squid
    SQUID_PREFIX="/usr"
    SQUID_LIBEXEC="/usr/lib/squid"

    echo ""
}

build_squid() {
    print_separator
    echo -e "${BOLD}Building Squid from source...${NC}"
    echo ""

    # Extra build deps not needed for apt path
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential pkg-config perl m4 \
        libssl-dev libexpat1-dev libxml2-dev \
        zlib1g-dev libcppunit-dev libecap3-dev \
        libdb-dev libsasl2-dev libldap2-dev libpam0g-dev \
        xz-utils tar

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
    run_logged_command "Configuring build" "/tmp/squid-configure.log" ./configure \
        --prefix="$SQUID_PREFIX" \
        --sysconfdir="$SQUID_ETC_DIR" \
        --localstatedir=/var \
        --libexecdir="$SQUID_PREFIX/libexec" \
        --with-default-user=proxy \
        --with-openssl \
        --enable-auth-basic=NCSA \
        --disable-translation \
        --with-filedescriptors=100000 || {
        print_error "Configure failed. See /tmp/squid-configure.log"
        exit 1
    }

    print_info "Compilation can stay CPU-bound and quiet for several minutes on small servers"
    echo -n "Compiling (jobs=$BUILD_JOBS)... "
    run_logged_command "Compiling (jobs=$BUILD_JOBS)" "/tmp/squid-build.log" make -j"$BUILD_JOBS" || {
        print_error "Build failed. See /tmp/squid-build.log"
        exit 1
    }

    echo -n "Installing... "
    run_logged_command "Installing" "/tmp/squid-install.log" make install || {
        print_error "Install failed. See /tmp/squid-install.log"
        exit 1
    }

    SQUID_LIBEXEC="$SQUID_PREFIX/libexec"
    print_success "Installed Squid ${SQUID_VERSION} at ${SQUID_PREFIX}"
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

configure_dns() {
    print_separator
    echo -e "${BOLD}Configuring public DNS (1.1.1.1 / 8.8.8.8)...${NC}"
    echo ""

    local dns1="1.1.1.1"
    local dns2="8.8.8.8"
    local dns3="8.8.4.4"
    local configured=0

    # Try systemd-resolved first
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local resolved_conf="/etc/systemd/resolved.conf.d/squid-proxy-dns.conf"
        mkdir -p "$(dirname "$resolved_conf")"
        cat > "$resolved_conf" <<EOF
[Resolve]
DNS=$dns1 $dns2 $dns3
FallbackDNS=
DNSStubListener=yes
EOF
        systemctl restart systemd-resolved
        print_success "systemd-resolved configured with $dns1 $dns2 $dns3"
        configured=1
    fi

    # Also write /etc/resolv.conf directly (works regardless of resolved)
    local resolv_conf="/etc/resolv.conf"
    # If it's a symlink managed by systemd-resolved, update /etc/resolv.conf via resolvectl
    if [ -L "$resolv_conf" ] && [ "$configured" -eq 1 ]; then
        # resolved will regenerate the stub; verify DNS shows our servers
        if resolvectl dns 2>/dev/null | grep -q "$dns1"; then
            print_success "/etc/resolv.conf managed by systemd-resolved (stub active)"
        else
            print_warning "systemd-resolved active but $dns1 not visible in resolvectl dns output"
        fi
    else
        # Either not a symlink or resolved not running — write directly
        # Back up only if not already our version
        if ! grep -q "# squid-proxy-dns" "$resolv_conf" 2>/dev/null; then
            cp "$resolv_conf" "${resolv_conf}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        fi
        cat > "$resolv_conf" <<EOF
# squid-proxy-dns — managed by proxy-squid-v4.sh
nameserver $dns1
nameserver $dns2
nameserver $dns3
options timeout:2 attempts:3
EOF
        print_success "/etc/resolv.conf updated with $dns1 $dns2 $dns3"
        configured=1
    fi

    # Quick sanity check
    if getent hosts cloudflare.com > /dev/null 2>&1; then
        print_success "DNS resolution test passed (cloudflare.com)"
    else
        print_warning "DNS resolution test failed — check /etc/resolv.conf and network"
    fi

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

# PLACEHOLDER — replaced below; kept so validate_pinned_release reference is intact
_build_squid_unused() {
    # This function is intentionally empty; build_squid() inside install_squid_apt
    # block handles source builds for older distros.
    :
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

    # Logrotate for squid error log
    cat > /etc/logrotate.d/squid-v4 <<'LOGROTATE'
/var/log/squid/errors.log
/var/log/squid/cache.log
{
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 proxy proxy
    postrotate
        systemctl reload squid 2>/dev/null || true
    endscript
}
LOGROTATE

    print_success "Runtime directories and credentials prepared"
    echo ""
}

write_squid_config() {
    print_separator
    echo -e "${BOLD}Writing squid.conf (stable forward-proxy profile)...${NC}"
    echo ""

    cat > "$SQUID_ETC_DIR/squid.conf" <<EOF
# Squid Forward Proxy ${SCRIPT_REV}
# Focus: stability under high CONNECT concurrency

workers $SQUID_WORKERS
max_filedescriptors 100000

http_port $HTTP_PORT
pid_filename /run/squid/squid.pid
coredump_dir $SQUID_SPOOL_DIR

# Authentication
auth_param basic program $SQUID_LIBEXEC/basic_ncsa_auth $SQUID_PASSWD_FILE
auth_param basic children $AUTH_CHILDREN
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
cache_mem 0 MB
maximum_object_size 0 KB
# memory_pools left at default (on) — with jemalloc, Squid's internal pools
# are managed efficiently; turning them off causes glibc heap fragmentation
# per Squid docs: https://wiki.squid-cache.org/SquidFaq/SquidMemory

# Disable cache digest (no caching = no digest needed; avoids CPU burn)
digest_generation off

# Disable pinger (ICMP ping helper — not needed for forward proxy)
pinger_enable off

# Logs — access log disabled (high-volume checker workload; errors go to cache.log)
access_log none
cache_store_log none
cache_log $SQUID_LOG_DIR/cache.log

# DNS — use public resolvers directly (VPS DNS can be slow under high load)
dns_nameservers 1.1.1.1 8.8.8.8 8.8.4.4
dns_timeout 10 seconds
negative_ttl 1 minute

# Connection behavior tuned for forward proxy stability
connect_timeout 15 seconds
read_timeout 45 seconds
request_timeout 45 seconds
client_idle_pconn_timeout 15 seconds
pconn_timeout 8 seconds
forward_timeout 15 seconds
shutdown_lifetime 3 seconds

# Important stability defaults (v3 bugfix)
half_closed_clients off
pipeline_prefetch 0

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
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.netfilter.nf_conntrack_max = 262144
vm.swappiness = 10
EOF

    # Ensure nf_conntrack module is loaded now and persists across reboots
    modprobe nf_conntrack 2>/dev/null || true
    echo 'nf_conntrack' > /etc/modules-load.d/nf_conntrack.conf
    print_info "nf_conntrack module loaded and persisted via /etc/modules-load.d/nf_conntrack.conf"

    print_info "Applying sysctl profile from /etc/sysctl.d/99-squid-proxy-v4.conf"
    sysctl --system
    verify_conntrack_tuning
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

find_jemalloc_so() {
    # ldconfig is the authoritative source — use it first
    local ldconfig_path
    ldconfig_path=$(ldconfig -p 2>/dev/null | grep "libjemalloc\.so\.2" | awk '{print $NF}' | head -1)
    if [ -n "$ldconfig_path" ] && [ -f "$ldconfig_path" ]; then
        echo "$ldconfig_path"
        return 0
    fi

    # Fallback: try common paths in order
    local candidates=(
        /lib/x86_64-linux-gnu/libjemalloc.so.2
        /lib/aarch64-linux-gnu/libjemalloc.so.2
        /usr/lib/x86_64-linux-gnu/libjemalloc.so.2
        /usr/lib/aarch64-linux-gnu/libjemalloc.so.2
        /usr/lib/libjemalloc.so.2
        /usr/local/lib/libjemalloc.so.2
    )
    for p in "${candidates[@]}"; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
}

write_systemd_unit() {
    print_separator
    echo -e "${BOLD}Creating systemd unit...${NC}"
    echo ""

    local jemalloc_so
    jemalloc_so=$(find_jemalloc_so)

    local ld_preload_line=""
    if [ -n "$jemalloc_so" ]; then
        ld_preload_line="Environment=LD_PRELOAD=$jemalloc_so"
        print_success "jemalloc found: $jemalloc_so"
    else
        print_warning "libjemalloc2 not found — Squid will use default glibc malloc (memory may grow unbounded)"
    fi

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
${ld_preload_line}
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

    # Verify jemalloc is loaded
    # Check /proc/PID/maps for every squid-related process
    local jemalloc_verified=0
    local wait_i
    for wait_i in 1 2 3 4 5; do
        local pid
        for pid in $(pgrep -a squid 2>/dev/null | awk '{print $1}' || true); do
            if grep -q "libjemalloc" /proc/"$pid"/maps 2>/dev/null; then
                local jemalloc_path
                jemalloc_path=$(grep "libjemalloc" /proc/"$pid"/maps 2>/dev/null | awk '{print $NF}' | head -1)
                print_success "jemalloc confirmed loaded (PID=$pid, $jemalloc_path)"
                jemalloc_verified=1
                break 2
            fi
        done
        sleep 2
    done
    if [ "$jemalloc_verified" -eq 0 ]; then
        print_warning "jemalloc NOT confirmed in any squid process — glibc malloc may be in use"
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
echo "jemalloc:"
JEMALLOC_OK=0
for PID in $(pgrep -a squid 2>/dev/null | awk '{print $1}' || true); do
    if grep -q "libjemalloc" /proc/"$PID"/maps 2>/dev/null; then
        JPATH=$(grep "libjemalloc" /proc/"$PID"/maps 2>/dev/null | awk '{print $NF}' | head -1)
        echo "  [OK] jemalloc loaded (PID=$PID, path=$JPATH)"
        JEMALLOC_OK=1
        break
    fi
done
if [ "$JEMALLOC_OK" -eq 0 ]; then
    echo "  [WARN] jemalloc NOT loaded in any squid process"
fi
echo ""
echo "Socket states on :$PORT"
ss -ant "( sport = :$PORT or dport = :$PORT )" | awk 'NR>1{c[$1]++} END{for (s in c) print s, c[s]}'
echo ""
echo "Kernel conntrack:"
COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
BUCKETS=$(cat /proc/sys/net/netfilter/nf_conntrack_buckets 2>/dev/null || echo 0)
echo "  count=$COUNT  max=$MAX  buckets=$BUCKETS"
if [ "$MAX" -gt 0 ]; then
    PCT=$(( COUNT * 100 / MAX ))
    echo "  usage=$PCT%"
    if [ "$PCT" -gt 80 ]; then
        echo "  [WARN] conntrack table >80% full — risk of dropped connections"
    fi
fi
echo ""
echo "Recent conntrack drops (last 1h):"
dmesg --since "1 hour ago" 2>/dev/null | grep -i "nf_conntrack.*full" | tail -5 || echo "  none"
echo ""
echo "Squid error/warn count (last 1h):"
journalctl -u squid --since "1 hour ago" --no-pager 2>/dev/null | grep -cE "ERR|WARN|assert" || echo "  0"
echo ""
echo "Recent squid assertions:"
journalctl -u squid -n 200 --no-pager | grep -E "assertion failed|will not be restarted" || echo "  none"
echo ""
echo "Error log tail (last 20 lines):"
tail -n 20 /var/log/squid/errors.log 2>/dev/null || echo "  (no errors.log yet)"
echo ""
echo "Cache log tail (last 10 lines):"
tail -n 10 /var/log/squid/cache.log 2>/dev/null || true
EOF

    chmod +x /root/monitor_squid_v4.sh
}

save_details() {
    cat > /root/proxy_details.txt <<EOF
Squid Forward Proxy ${SCRIPT_REV}
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
    echo "Username     : $PROXY_USER"
    echo "Password     : $PROXY_PASS"
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
    run_step "configure_dns" configure_dns
    run_step "stop_old_squid" stop_old_squid

    # Ubuntu 24.04+: use apt (Squid 6 available, no compile needed — ~2 min)
    # Older distros: fall back to source build (~10-15 min on 1 vCPU)
    if can_use_apt_squid6; then
        print_info "Ubuntu 24.04+ detected — using apt to install Squid 6 (fast path)"
        run_step "install_squid_apt" install_squid_apt
    else
        print_info "Older distro detected — building Squid from source"
        run_step "build_squid" build_squid
    fi

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
