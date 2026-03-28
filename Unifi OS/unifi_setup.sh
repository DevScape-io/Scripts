#!/bin/bash
# =============================================================================
# Host Setup Script
# - System update & upgrade
# - Static IP: 10.20.1.1/24
# - DHCP server (dnsmasq) on 10.20.1.0/24
# - DNS Forwarding (dnsmasq)
# - UniFi Network Application
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/setup.sh | sudo bash
#   -- or --
#   sudo bash setup.sh
# =============================================================================

set -euo pipefail

# ---------- Colors -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
info()    { echo -e "${CYAN}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $1${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"; }

# ---------- Root check -------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"

# ---------- Config -----------------------------------------------------------
STATIC_IP="10.20.1.1"
SUBNET_PREFIX="24"
DHCP_RANGE_START="10.20.1.100"
DHCP_RANGE_END="10.20.1.254"
DHCP_LEASE="12h"
DNS_UPSTREAM_1="1.1.1.1"
DNS_UPSTREAM_2="8.8.8.8"

# Detect the primary non-loopback interface
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E '^lo$|^docker|^veth|^br-' | head -n1)
[[ -z "$IFACE" ]] && error "Could not detect a network interface. Set IFACE manually."
info "Detected interface: ${BOLD}$IFACE${NC}"

# =============================================================================
# 1. SYSTEM UPDATE & UPGRADE
# =============================================================================
section "1 · System update & upgrade"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y
apt-get autoclean -y
log "System updated and upgraded."

# =============================================================================
# 2. STATIC IP
# =============================================================================
section "2 · Static IP → ${STATIC_IP}/${SUBNET_PREFIX} on ${IFACE}"

# Detect whether this system uses NetworkManager or dhcpcd
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    info "NetworkManager detected — configuring via nmcli."

    CONN_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep ":${IFACE}$" | cut -d: -f1 || true)
    if [[ -z "$CONN_NAME" ]]; then
        CONN_NAME="static-${IFACE}"
        nmcli con add type ethernet ifname "$IFACE" con-name "$CONN_NAME"
    fi

    nmcli con mod "$CONN_NAME" \
        ipv4.method manual \
        ipv4.addresses "${STATIC_IP}/${SUBNET_PREFIX}" \
        ipv4.gateway "$STATIC_IP" \
        ipv4.dns "${DNS_UPSTREAM_1} ${DNS_UPSTREAM_2}" \
        connection.autoconnect yes

    nmcli con up "$CONN_NAME" || warn "Could not bring up connection immediately — will apply on next boot."
    log "Static IP configured via NetworkManager."

elif systemctl list-unit-files dhcpcd.service 2>/dev/null | grep -q dhcpcd; then
    info "dhcpcd detected — configuring via /etc/dhcpcd.conf."

    DHCPCD_CONF="/etc/dhcpcd.conf"
    cp "${DHCPCD_CONF}" "${DHCPCD_CONF}.bak.$(date +%s)"

    # Remove any existing block for this interface
    sed -i "/^interface ${IFACE}/,/^$/d" "$DHCPCD_CONF"

    cat >> "$DHCPCD_CONF" <<EOF

# Static IP added by setup.sh
interface ${IFACE}
static ip_address=${STATIC_IP}/${SUBNET_PREFIX}
static routers=${STATIC_IP}
static domain_name_servers=${DNS_UPSTREAM_1} ${DNS_UPSTREAM_2}
nohook wpa_supplicant
EOF

    systemctl restart dhcpcd || warn "dhcpcd restart failed — changes apply on reboot."
    log "Static IP configured via dhcpcd."

else
    # Fallback: write a systemd-networkd .network file
    warn "Neither NetworkManager nor dhcpcd found. Falling back to systemd-networkd."
    mkdir -p /etc/systemd/network

    cat > "/etc/systemd/network/10-${IFACE}-static.network" <<EOF
[Match]
Name=${IFACE}

[Network]
Address=${STATIC_IP}/${SUBNET_PREFIX}
Gateway=${STATIC_IP}
DNS=${DNS_UPSTREAM_1}
DNS=${DNS_UPSTREAM_2}
EOF

    systemctl enable systemd-networkd
    systemctl restart systemd-networkd
    log "Static IP configured via systemd-networkd."
fi

# =============================================================================
# 3. DHCP + DNS FORWARDING (dnsmasq)
# =============================================================================
section "3 · DHCP & DNS forwarding (dnsmasq)"

apt-get install -y dnsmasq

# Always disable systemd-resolved — conflicts with dnsmasq on port 53
# and can be re-enabled by DHCP/NetworkManager if not fully stopped
log "Disabling systemd-resolved (conflicts with dnsmasq)..."
systemctl stop systemd-resolved    2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
systemctl mask systemd-resolved    2>/dev/null || true   # mask prevents any re-enable

# Remove the stub resolver symlink and write a static resolv.conf
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver ${DNS_UPSTREAM_1}
nameserver ${DNS_UPSTREAM_2}
EOF
chattr +i /etc/resolv.conf   # immutable — DHCP clients cannot overwrite this

# Tell NetworkManager to manage DNS itself rather than handing off to systemd-resolved
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/no-resolved.conf <<NM_EOF
[main]
dns=none
systemd-resolved=false
NM_EOF
    systemctl reload NetworkManager 2>/dev/null || true
    log "NetworkManager configured to not use systemd-resolved."
fi

# Backup existing config
DNSMASQ_CONF="/etc/dnsmasq.conf"
[[ -f "$DNSMASQ_CONF" ]] && cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak.$(date +%s)"

cat > "$DNSMASQ_CONF" <<EOF
# dnsmasq configuration — generated by setup.sh
# -------------------------------------------------

# Network interface to listen on
interface=${IFACE}
bind-interfaces

# DHCP pool
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}

# Default gateway & DNS pushed to clients
dhcp-option=3,${STATIC_IP}
dhcp-option=6,${STATIC_IP}

# DNS Forwarding — upstream resolvers
server=${DNS_UPSTREAM_1}
server=${DNS_UPSTREAM_2}

# Cache size (DNS queries)
cache-size=1000

# Prevent forwarding bare (unqualified) hostnames to upstream
domain-needed
bogus-priv

# Log DHCP transactions (remove if log volume is a concern)
log-dhcp

# Example: reserve a static lease
# dhcp-host=aa:bb:cc:dd:ee:ff,10.20.1.10,hostname,infinite
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

# Quick sanity check
if systemctl is-active --quiet dnsmasq; then
    log "dnsmasq is running. DHCP range: ${DHCP_RANGE_START} – ${DHCP_RANGE_END}"
else
    error "dnsmasq failed to start. Run: journalctl -xeu dnsmasq.service"
fi

# =============================================================================
# 4. UNIFI NETWORK APPLICATION
# =============================================================================
section "4 · UniFi Network Application"

# Dependencies
apt-get install -y curl gnupg ca-certificates apt-transport-https

# Java 17
if ! java -version 2>&1 | grep -q '17\|21'; then
    log "Installing OpenJDK 17..."
    apt-get install -y openjdk-17-jre-headless
else
    info "Java 17+ already present — skipping."
fi

# MongoDB 7.0 (required by UniFi 8.x; supports Ubuntu 24.04 Noble via jammy repo)
if ! command -v mongod &>/dev/null; then
    log "Adding MongoDB 7.0 repository..."

    ARCH=$(dpkg --print-architecture)
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

    # Remove any stale MongoDB repo files
    rm -f /etc/apt/sources.list.d/mongodb-org-4.4.list
    rm -f /usr/share/keyrings/mongodb-server-4.4.gpg

    # MongoDB 7.0 has no Noble (24.04) package yet — jammy works on Noble fine
    case "$CODENAME" in
        noble|jammy|focal)         MONGO_DIST="jammy" ;;
        bookworm|bullseye|buster)  MONGO_DIST="jammy" ;;
        *)                         MONGO_DIST="jammy" ;;
    esac

    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

    echo "deb [ arch=${ARCH} signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu ${MONGO_DIST}/mongodb-org/7.0 multiverse" \
        | tee /etc/apt/sources.list.d/mongodb-org-7.0.list

    apt-get update -y
    apt-get install -y mongodb-org
    systemctl enable mongod
    systemctl start mongod

    # Give mongod a moment to fully start before UniFi tries to connect
    sleep 3
    if systemctl is-active --quiet mongod; then
        log "MongoDB 7.0 installed and running."
    else
        error "MongoDB failed to start. Run: journalctl -xeu mongod.service"
    fi
else
    info "mongod already installed — skipping."
    systemctl is-active --quiet mongod || systemctl start mongod
fi

# UniFi Network Application
log "Adding UniFi repository..."
curl -fsSL https://dl.ui.com/unifi/debian/unifi-repo.gpg \
    | gpg --dearmor -o /usr/share/keyrings/unifi-repo.gpg

echo "deb [signed-by=/usr/share/keyrings/unifi-repo.gpg] \
https://www.ui.com/downloads/unifi/debian stable ubiquiti" \
    | tee /etc/apt/sources.list.d/unifi.list

apt-get update -y
apt-get install -y unifi

systemctl enable unifi
systemctl start unifi

# Wait a moment for it to bind
sleep 5
if systemctl is-active --quiet unifi; then
    log "UniFi Network Application is running."
else
    warn "UniFi may still be starting up. Check: systemctl status unifi"
fi

# =============================================================================
# DONE — Summary
# =============================================================================
section "Setup complete"

echo -e "
  ${GREEN}Static IP   ${NC} ${STATIC_IP}/${SUBNET_PREFIX}  (${IFACE})
  ${GREEN}DHCP range  ${NC} ${DHCP_RANGE_START} – ${DHCP_RANGE_END}  (${DHCP_LEASE} leases)
  ${GREEN}DNS upstream${NC} ${DNS_UPSTREAM_1}  ${DNS_UPSTREAM_2}
  ${GREEN}UniFi UI    ${NC} https://${STATIC_IP}:8443

  ${YELLOW}Next steps:${NC}
    • Open https://${STATIC_IP}:8443 in a browser to finish UniFi setup
    • Add static DHCP leases in /etc/dnsmasq.conf  (dhcp-host= lines)
    • Review firewall rules if this host is behind NAT
    • A reboot is recommended to confirm all changes survive restart
"