#!/bin/bash
# ============================================================
#  net-config.sh — Interactive Hostname & Network Configurator
#  Supports: Netplan (Ubuntu 18+), NetworkManager (nmcli),
#            and /etc/network/interfaces (Debian/older systems)
#  Run as root: sudo bash net-config.sh
# ============================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "This script must be run as root (sudo $0)"

# ── Banner ───────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║       Linux Network Configuration Utility        ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Detect backend ───────────────────────────────────────────
detect_backend() {
    if command -v netplan &>/dev/null && ls /etc/netplan/*.yaml &>/dev/null 2>&1; then
        echo "netplan"
    elif command -v nmcli &>/dev/null; then
        echo "networkmanager"
    elif [[ -f /etc/network/interfaces ]]; then
        echo "interfaces"
    else
        echo "unknown"
    fi
}

BACKEND=$(detect_backend)
info "Detected network backend: ${BOLD}${BACKEND}${RESET}"
echo

# ── List available interfaces ────────────────────────────────
get_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'
}

IFACES=($(get_interfaces))
[[ ${#IFACES[@]} -eq 0 ]] && die "No network interfaces found."

# ── Helpers ──────────────────────────────────────────────────
prompt() {
    # prompt <var_name> <message> [default]
    local __var=$1 msg=$2 default=${3:-}
    local input
    if [[ -n $default ]]; then
        read -rp "$(echo -e "${BOLD}${msg}${RESET} [${default}]: ")" input
        input="${input:-$default}"
    else
        while [[ -z ${input:-} ]]; do
            read -rp "$(echo -e "${BOLD}${msg}${RESET}: ")" input
        done
    fi
    printf -v "$__var" '%s' "$input"
}

validate_ip() {
    local ip=$1
    local IFS='.'
    read -ra o <<< "$ip"
    [[ ${#o[@]} -eq 4 ]] || return 1
    for seg in "${o[@]}"; do
        [[ $seg =~ ^[0-9]+$ ]] && (( seg >= 0 && seg <= 255 )) || return 1
    done
}

validate_cidr() {
    local cidr=$1
    [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
}

mask_to_cidr() {
    local mask=$1
    local cidr=0
    local IFS='.'
    read -ra octets <<< "$mask"
    for o in "${octets[@]}"; do
        for (( i=7; i>=0; i-- )); do
            (( (o >> i) & 1 )) && (( cidr++ )) || break
        done
    done
    echo "$cidr"
}

# ── Step 1: Hostname ─────────────────────────────────────────
echo -e "${BOLD}── Step 1: Hostname ──────────────────────────────────${RESET}"
CURRENT_HOSTNAME=$(hostname)
prompt NEW_HOSTNAME "New hostname" "$CURRENT_HOSTNAME"

# Basic hostname validation
[[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] \
    || die "Invalid hostname: '$NEW_HOSTNAME'. Use only letters, numbers, and hyphens."
echo

# ── Step 2: Interface selection ──────────────────────────────
echo -e "${BOLD}── Step 2: Network Interface ─────────────────────────${RESET}"
echo "Available interfaces:"
for i in "${!IFACES[@]}"; do
    IP_ADDR=$(ip -4 addr show "${IFACES[$i]}" 2>/dev/null | awk '/inet /{print $2}' | head -1)
    printf "  ${CYAN}%d)${RESET} %-12s %s\n" "$((i+1))" "${IFACES[$i]}" "${IP_ADDR:-[no IP]}"
done
echo

while true; do
    prompt IFACE_CHOICE "Select interface number" "1"
    if [[ $IFACE_CHOICE =~ ^[0-9]+$ ]] \
        && (( IFACE_CHOICE >= 1 && IFACE_CHOICE <= ${#IFACES[@]} )); then
        IFACE="${IFACES[$((IFACE_CHOICE-1))]}"
        break
    fi
    warn "Invalid selection, try again."
done

info "Using interface: ${BOLD}${IFACE}${RESET}"
echo

# ── Step 3: DHCP or Static ───────────────────────────────────
echo -e "${BOLD}── Step 3: IP Address Method ─────────────────────────${RESET}"
while true; do
    prompt IP_METHOD "IP method — enter  dhcp  or  static" "dhcp"
    IP_METHOD="${IP_METHOD,,}"
    [[ $IP_METHOD == "dhcp" || $IP_METHOD == "static" ]] && break
    warn "Please enter 'dhcp' or 'static'."
done
echo

# ── Step 4 (static only): Gather static IP details ───────────
if [[ $IP_METHOD == "static" ]]; then
    echo -e "${BOLD}── Step 4: Static IP Configuration ───────────────────${RESET}"

    # IP Address
    while true; do
        prompt STATIC_IP "IP Address (e.g. 192.168.1.100)"
        validate_ip "$STATIC_IP" && break
        warn "'$STATIC_IP' is not a valid IP address."
    done

    # Subnet — accept mask or CIDR prefix
    while true; do
        prompt SUBNET_INPUT "Subnet Mask or CIDR prefix (e.g. 255.255.255.0 or 24)"
        if [[ $SUBNET_INPUT =~ ^[0-9]+$ ]] && (( SUBNET_INPUT >= 0 && SUBNET_INPUT <= 32 )); then
            CIDR_PREFIX="$SUBNET_INPUT"
            break
        elif validate_ip "$SUBNET_INPUT"; then
            CIDR_PREFIX=$(mask_to_cidr "$SUBNET_INPUT")
            break
        fi
        warn "Invalid subnet. Use dotted-decimal (255.255.255.0) or prefix length (24)."
    done

    STATIC_CIDR="${STATIC_IP}/${CIDR_PREFIX}"

    # Gateway
    DEFAULT_GW=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1)
    while true; do
        prompt GATEWAY "Default Gateway" "${DEFAULT_GW:-}"
        validate_ip "$GATEWAY" && break
        warn "'$GATEWAY' is not a valid IP address."
    done

    # DNS servers
    echo -e "${BOLD}DNS Servers${RESET} (space-separated, e.g.  8.8.8.8 8.8.4.4)"
    prompt DNS_INPUT "DNS Server(s)" "8.8.8.8 8.8.4.4"
    read -ra DNS_SERVERS <<< "$DNS_INPUT"
    for dns in "${DNS_SERVERS[@]}"; do
        validate_ip "$dns" || { warn "'$dns' is not a valid IP — using defaults."; DNS_SERVERS=("8.8.8.8" "8.8.4.4"); break; }
    done

    # Search domain (optional)
    prompt SEARCH_DOMAIN "DNS Search Domain (leave blank to skip)" ""
    echo
fi

# ── Step 5: Confirm ──────────────────────────────────────────
echo -e "${BOLD}── Summary ───────────────────────────────────────────${RESET}"
echo -e "  Hostname   : ${CYAN}${NEW_HOSTNAME}${RESET}"
echo -e "  Interface  : ${CYAN}${IFACE}${RESET}"
echo -e "  Method     : ${CYAN}${IP_METHOD^^}${RESET}"
if [[ $IP_METHOD == "static" ]]; then
    echo -e "  IP/CIDR    : ${CYAN}${STATIC_CIDR}${RESET}"
    echo -e "  Gateway    : ${CYAN}${GATEWAY}${RESET}"
    echo -e "  DNS        : ${CYAN}${DNS_SERVERS[*]}${RESET}"
    [[ -n ${SEARCH_DOMAIN:-} ]] && echo -e "  Search     : ${CYAN}${SEARCH_DOMAIN}${RESET}"
fi
echo
read -rp "$(echo -e "${YELLOW}Apply these settings? [y/N]: ${RESET}")" CONFIRM
[[ ${CONFIRM,,} == "y" ]] || { info "Aborted. No changes made."; exit 0; }
echo

# ── Apply: Hostname ──────────────────────────────────────────
apply_hostname() {
    info "Setting hostname to '${NEW_HOSTNAME}' …"
    echo "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME"
    # Update /etc/hosts — replace old hostname entries
    sed -i "s/\b${CURRENT_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts
    # Ensure 127.0.1.1 entry exists
    if ! grep -q "127.0.1.1" /etc/hosts; then
        echo "127.0.1.1  ${NEW_HOSTNAME}" >> /etc/hosts
    fi
    success "Hostname updated."
}

# ── Apply: Netplan ───────────────────────────────────────────
apply_netplan() {
    local cfg="/etc/netplan/99-net-config.yaml"
    info "Writing Netplan config to ${cfg} …"

    if [[ $IP_METHOD == "dhcp" ]]; then
        cat > "$cfg" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: true
      dhcp6: false
EOF
    else
        local dns_yaml
        dns_yaml=$(printf '          - %s\n' "${DNS_SERVERS[@]}")
        local search_yaml=""
        [[ -n ${SEARCH_DOMAIN:-} ]] && search_yaml=$(printf '          - %s' "$SEARCH_DOMAIN")

        cat > "$cfg" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_CIDR}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
${dns_yaml}
EOF
        if [[ -n ${SEARCH_DOMAIN:-} ]]; then
            cat >> "$cfg" <<EOF
        search:
          - ${SEARCH_DOMAIN}
EOF
        fi
    fi

    chmod 600 "$cfg"
    info "Applying Netplan …"
    netplan apply
    success "Netplan configuration applied."
}

# ── Apply: NetworkManager ────────────────────────────────────
apply_networkmanager() {
    local CON_NAME="net-config-${IFACE}"
    info "Configuring via NetworkManager …"

    # Remove any existing connection for this interface
    nmcli con delete "$CON_NAME" &>/dev/null || true
    nmcli con delete id "$IFACE"  &>/dev/null || true

    if [[ $IP_METHOD == "dhcp" ]]; then
        nmcli con add type ethernet \
            con-name "$CON_NAME" \
            ifname   "$IFACE"    \
            ipv4.method auto     \
            ipv6.method ignore
    else
        local dns_nm
        dns_nm=$(IFS=','; echo "${DNS_SERVERS[*]}")
        nmcli con add type ethernet \
            con-name        "$CON_NAME"   \
            ifname          "$IFACE"      \
            ipv4.method     manual        \
            ipv4.addresses  "$STATIC_CIDR" \
            ipv4.gateway    "$GATEWAY"    \
            ipv4.dns        "$dns_nm"     \
            ipv6.method     ignore
        [[ -n ${SEARCH_DOMAIN:-} ]] && \
            nmcli con mod "$CON_NAME" ipv4.dns-search "$SEARCH_DOMAIN"
    fi

    nmcli con up "$CON_NAME"
    success "NetworkManager configuration applied."
}

# ── Apply: /etc/network/interfaces ───────────────────────────
apply_interfaces() {
    local cfg="/etc/network/interfaces"
    local bak="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backing up ${cfg} to ${bak} …"
    cp "$cfg" "$bak"

    info "Updating ${cfg} …"

    # Remove existing stanza for this interface
    python3 - "$cfg" "$IFACE" <<'PYEOF'
import sys, re

cfg_path = sys.argv[1]
iface    = sys.argv[2]

with open(cfg_path) as f:
    content = f.read()

# Remove iface block for the given interface (allow/iface lines)
pattern = rf'(?m)^(allow-hotplug|auto)\s+{re.escape(iface)}\s*\n(iface\s+{re.escape(iface)}\s.*\n(?:(?!\S).*\n)*)?'
content = re.sub(pattern, '', content)

with open(cfg_path, 'w') as f:
    f.write(content.rstrip('\n') + '\n')
PYEOF

    if [[ $IP_METHOD == "dhcp" ]]; then
        cat >> "$cfg" <<EOF

auto ${IFACE}
iface ${IFACE} inet dhcp
EOF
    else
        cat >> "$cfg" <<EOF

auto ${IFACE}
iface ${IFACE} inet static
    address    ${STATIC_IP}
    netmask    $(python3 -c "
p=${CIDR_PREFIX}
m=((1<<32)-(1<<(32-p)))
print('.'.join(str((m>>(8*i))&0xff) for i in range(3,-1,-1)))
")
    gateway    ${GATEWAY}
    dns-nameservers ${DNS_SERVERS[*]}
EOF
        [[ -n ${SEARCH_DOMAIN:-} ]] && echo "    dns-search ${SEARCH_DOMAIN}" >> "$cfg"
    fi

    info "Restarting networking …"
    systemctl restart networking || ifdown "$IFACE" && ifup "$IFACE"
    success "/etc/network/interfaces updated."
}

# ── Dispatch ─────────────────────────────────────────────────
apply_hostname

case "$BACKEND" in
    netplan)        apply_netplan ;;
    networkmanager) apply_networkmanager ;;
    interfaces)     apply_interfaces ;;
    *)  warn "Unknown backend — hostname was set, but network config was NOT written."
        warn "Manually configure your network manager." ;;
esac

echo
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Configuration complete!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}"
echo
info "New hostname : ${BOLD}${NEW_HOSTNAME}${RESET}"
info "Interface    : ${BOLD}${IFACE}${RESET}  (${IP_METHOD^^})"
[[ $IP_METHOD == "static" ]] && info "Address      : ${BOLD}${STATIC_CIDR}${RESET}  gw ${GATEWAY}"
echo