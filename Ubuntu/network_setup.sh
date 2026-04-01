#!/bin/bash
# ============================================================
#  net-config.sh — Interactive Hostname & Network Configurator
#  Pre-populates every field from the live system.
#  When run over SSH, always prompts for ALL fields.
#
#  Supports: Netplan (Ubuntu 18+), NetworkManager (nmcli),
#            /etc/network/interfaces (Debian/older)
#
#  Run as root: sudo bash net-config.sh
# ============================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
sep()     { echo -e "${DIM}────────────────────────────────────────────────────${RESET}"; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root:  sudo $0"

# ── Detect SSH / remote session ──────────────────────────────
IS_REMOTE=false
[[ -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" || -n "${SSH_CONNECTION:-}" ]] && IS_REMOTE=true

# ── Detect network backend ───────────────────────────────────
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

# ── Banner ───────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║       Linux Network Configuration Utility        ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
info "Network backend: ${BOLD}${BACKEND}${RESET}"
echo

if $IS_REMOTE; then
    echo -e "${YELLOW}${BOLD}  ⚠  Remote / SSH session detected.${RESET}"
    echo -e "${YELLOW}     All fields will be prompted, including static IP.${RESET}"
    echo -e "${YELLOW}     Changing the IP address WILL drop this connection.${RESET}"
    echo
fi

# ── Helpers: read current state ──────────────────────────────
get_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'
}

get_current_ip() {
    ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d/ -f1
}

get_current_prefix() {
    ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d/ -f2
}

get_current_gateway() {
    ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1
}

get_current_dns() {
    local dns=""
    if command -v resolvectl &>/dev/null; then
        dns=$(resolvectl status 2>/dev/null | awk '/DNS Servers/{$1=$2=""; print}' | tr '\n' ' ' | xargs)
    fi
    if [[ -z $dns && -f /etc/resolv.conf ]]; then
        dns=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf | xargs)
    fi
    echo "$dns"
}

get_current_search() {
    awk '/^search/{$1=""; print; exit}' /etc/resolv.conf 2>/dev/null | xargs
}

is_dhcp() {
    local iface=$1
    case "$BACKEND" in
        netplan)
            grep -rl "dhcp4: true" /etc/netplan/ 2>/dev/null \
                | xargs grep -l "$iface" &>/dev/null && echo "dhcp" || echo "static"
            ;;
        networkmanager)
            local con method
            con=$(nmcli -g GENERAL.CONNECTION dev show "$iface" 2>/dev/null || true)
            method=$(nmcli -g ipv4.method con show "$con" 2>/dev/null || true)
            [[ $method == "auto" ]] && echo "dhcp" || echo "static"
            ;;
        interfaces)
            grep -A5 "iface $iface" /etc/network/interfaces 2>/dev/null \
                | grep -q "inet dhcp" && echo "dhcp" || echo "static"
            ;;
        *) echo "dhcp" ;;
    esac
}

cidr_to_mask() {
    local p=$1 mask="" i
    for (( i=0; i<4; i++ )); do
        if   (( i <  p/8 )); then mask+="255"
        elif (( i == p/8 )); then mask+=$(( 256 - (1 << (8 - p%8)) ))
        else mask+="0"
        fi
        (( i < 3 )) && mask+="."
    done
    echo "$mask"
}

mask_to_cidr() {
    local mask=$1 cidr=0 i
    local IFS='.'
    read -ra octs <<< "$mask"
    for o in "${octs[@]}"; do
        for (( i=7; i>=0; i-- )); do
            (( (o >> i) & 1 )) && (( cidr++ )) || break
        done
    done
    echo "$cidr"
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

# ── Prompt helper — pre-fills with existing value ────────────
# Usage:  prompt_field  VARNAME  "Label"  "current value"
prompt_field() {
    local __var=$1 label=$2 current=$3
    local input
    while true; do
        echo -ne "${BOLD}  ${label}${RESET}"
        [[ -n $current ]] && echo -ne " ${DIM}[${current}]${RESET}"
        echo -ne ": "
        read -r input
        input="${input:-$current}"
        if [[ -z $input ]]; then
            warn "  This field cannot be empty."
        else
            printf -v "$__var" '%s' "$input"
            return
        fi
    done
}

# ── STEP 1 · Hostname ────────────────────────────────────────
echo -e "${BOLD}── Step 1 · Hostname ─────────────────────────────────${RESET}"
CURRENT_HOSTNAME=$(hostname)
prompt_field NEW_HOSTNAME "Hostname" "$CURRENT_HOSTNAME"
[[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] \
    || die "Invalid hostname '$NEW_HOSTNAME'. Use letters, numbers, hyphens only."
echo

# ── STEP 2 · Interface ───────────────────────────────────────
echo -e "${BOLD}── Step 2 · Network Interface ────────────────────────${RESET}"
IFACES=($(get_interfaces))
[[ ${#IFACES[@]} -eq 0 ]] && die "No network interfaces found."

# Guess the active SSH interface
DEFAULT_IFACE="${IFACES[0]}"
if $IS_REMOTE && [[ -n "${SSH_CONNECTION:-}" ]]; then
    SSH_LOCAL_IP=$(echo "$SSH_CONNECTION" | awk '{print $3}')
    for ifc in "${IFACES[@]}"; do
        if ip -4 addr show "$ifc" 2>/dev/null | grep -q "$SSH_LOCAL_IP"; then
            DEFAULT_IFACE="$ifc"; break
        fi
    done
fi

echo "  Available interfaces:"
for i in "${!IFACES[@]}"; do
    ifc="${IFACES[$i]}"
    cur_ip=$(get_current_ip "$ifc")
    cur_pfx=$(get_current_prefix "$ifc")
    method=$(is_dhcp "$ifc")
    flag=""
    $IS_REMOTE && [[ $ifc == "$DEFAULT_IFACE" ]] && flag="  ${YELLOW}← active SSH interface${RESET}"
    printf "    ${CYAN}%d)${RESET} %-14s %-22s %-9s%b\n" \
        "$((i+1))" "$ifc" \
        "${cur_ip:+${cur_ip}/${cur_pfx:-?}}" \
        "(${method^^})" "$flag"
done
echo

DEFAULT_IDX=1
for i in "${!IFACES[@]}"; do
    [[ "${IFACES[$i]}" == "$DEFAULT_IFACE" ]] && DEFAULT_IDX=$((i+1))
done

while true; do
    prompt_field IFACE_CHOICE "Select interface number" "$DEFAULT_IDX"
    if [[ $IFACE_CHOICE =~ ^[0-9]+$ ]] \
        && (( IFACE_CHOICE >= 1 && IFACE_CHOICE <= ${#IFACES[@]} )); then
        IFACE="${IFACES[$((IFACE_CHOICE-1))]}"; break
    fi
    warn "  Invalid selection."
done

# Read the chosen interface's current values
CUR_IP=$(get_current_ip "$IFACE")
CUR_PREFIX=$(get_current_prefix "$IFACE")
CUR_MASK=""; [[ -n $CUR_PREFIX ]] && CUR_MASK=$(cidr_to_mask "$CUR_PREFIX")
CUR_GW=$(get_current_gateway)
CUR_DNS=$(get_current_dns)
CUR_SEARCH=$(get_current_search)
CUR_METHOD=$(is_dhcp "$IFACE")

info "Using: ${BOLD}${IFACE}${RESET}  (currently ${CUR_METHOD^^}  ${CUR_IP:-no IP})"
echo

# ── STEP 3 · DHCP or Static ─────────────────────────────────
echo -e "${BOLD}── Step 3 · IP Address Method ────────────────────────${RESET}"
while true; do
    prompt_field IP_METHOD "Method  (dhcp / static)" "$CUR_METHOD"
    IP_METHOD="${IP_METHOD,,}"
    [[ $IP_METHOD == "dhcp" || $IP_METHOD == "static" ]] && break
    warn "  Enter 'dhcp' or 'static'."
done
echo

# ── STEP 4 · Address fields ──────────────────────────────────
# Always shown for static.
# Always shown for SSH sessions regardless of method (so you
# know what to type to reconnect / set a safe fallback).
SHOW_STATIC_FIELDS=false
[[ $IP_METHOD == "static" ]] && SHOW_STATIC_FIELDS=true
$IS_REMOTE                   && SHOW_STATIC_FIELDS=true

if $SHOW_STATIC_FIELDS; then
    echo -e "${BOLD}── Step 4 · IP Address Details ───────────────────────${RESET}"

    if $IS_REMOTE && [[ $IP_METHOD == "dhcp" ]]; then
        echo -e "  ${YELLOW}You chose DHCP. The values below are written as a${RESET}"
        echo -e "  ${YELLOW}static fallback so you can reconnect if DHCP fails.${RESET}"
        echo
    fi

    # IP Address
    while true; do
        prompt_field STATIC_IP "IP Address" "${CUR_IP:-}"
        validate_ip "$STATIC_IP" && break
        warn "  Not a valid IPv4 address."
    done

    # Subnet
    while true; do
        prompt_field SUBNET_INPUT "Subnet Mask or prefix length" "${CUR_MASK:-${CUR_PREFIX:-24}}"
        if [[ $SUBNET_INPUT =~ ^[0-9]+$ ]] && (( SUBNET_INPUT >= 0 && SUBNET_INPUT <= 32 )); then
            CIDR_PREFIX="$SUBNET_INPUT"; break
        elif validate_ip "$SUBNET_INPUT" 2>/dev/null; then
            CIDR_PREFIX=$(mask_to_cidr "$SUBNET_INPUT"); break
        fi
        warn "  Enter a dotted mask (255.255.255.0) or prefix length (24)."
    done
    STATIC_CIDR="${STATIC_IP}/${CIDR_PREFIX}"

    # Gateway
    while true; do
        prompt_field GATEWAY "Default Gateway" "${CUR_GW:-}"
        validate_ip "$GATEWAY" && break
        warn "  Not a valid IPv4 address."
    done

    # DNS
    echo -e "  ${DIM}(Space-separated for multiple, e.g.  8.8.8.8 1.1.1.1)${RESET}"
    while true; do
        prompt_field DNS_INPUT "DNS Server(s)" "${CUR_DNS:-8.8.8.8 8.8.4.4}"
        read -ra DNS_SERVERS <<< "$DNS_INPUT"
        OK=true
        for dns in "${DNS_SERVERS[@]}"; do
            validate_ip "$dns" 2>/dev/null || { warn "  '$dns' is not a valid IP."; OK=false; break; }
        done
        $OK && break
    done

    # Search domain
    prompt_field SEARCH_DOMAIN "DNS Search Domain (blank to skip)" "${CUR_SEARCH:-}"
    echo
fi

# ── STEP 5 · Confirm ─────────────────────────────────────────
sep
echo -e "${BOLD}  Review changes${RESET}"
sep
printf "  %-20s ${DIM}%s${RESET}  →  ${CYAN}%s${RESET}\n" \
    "Hostname:"  "$CURRENT_HOSTNAME"  "$NEW_HOSTNAME"
printf "  %-20s ${CYAN}%s${RESET}\n" "Interface:"  "$IFACE"
printf "  %-20s ${DIM}%s${RESET}  →  ${CYAN}%s${RESET}\n" \
    "Method:"    "${CUR_METHOD^^}"    "${IP_METHOD^^}"

if $SHOW_STATIC_FIELDS; then
    OLD_CIDR="${CUR_IP:-?}/${CUR_PREFIX:-?}"
    printf "  %-20s ${DIM}%s${RESET}  →  ${CYAN}%s${RESET}\n" "IP/CIDR:"       "$OLD_CIDR"     "$STATIC_CIDR"
    printf "  %-20s ${DIM}%s${RESET}  →  ${CYAN}%s${RESET}\n" "Gateway:"        "${CUR_GW:-?}" "$GATEWAY"
    printf "  %-20s ${DIM}%s${RESET}  →  ${CYAN}%s${RESET}\n" "DNS:"            "${CUR_DNS:-?}" "${DNS_SERVERS[*]}"
    [[ -n ${SEARCH_DOMAIN:-} ]] && \
    printf "  %-20s ${DIM}%s${RESET}  →  ${CYAN}%s${RESET}\n" "Search Domain:"  "${CUR_SEARCH:-?}" "$SEARCH_DOMAIN"
fi
sep
echo

if $IS_REMOTE; then
    echo -e "${RED}${BOLD}  ⚠  You are on a REMOTE session.${RESET}"
    if $SHOW_STATIC_FIELDS; then
        echo -e "${RED}     If the IP changes, reconnect with:${RESET}"
        echo -e "${RED}     ssh <user>@${STATIC_IP}${RESET}"
    fi
    echo
fi

read -rp "$(echo -e "${YELLOW}${BOLD}  Apply these settings? [y/N]: ${RESET}")" CONFIRM
[[ ${CONFIRM,,} == "y" ]] || { info "Aborted — no changes written."; exit 0; }
echo

# ── Apply: Hostname ──────────────────────────────────────────
apply_hostname() {
    info "Setting hostname → '${NEW_HOSTNAME}' …"
    echo "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME"
    sed -i "s/\b${CURRENT_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts
    grep -q "127.0.1.1" /etc/hosts \
        || echo "127.0.1.1  ${NEW_HOSTNAME}" >> /etc/hosts
    success "Hostname updated."
}

# ── Apply: Netplan ───────────────────────────────────────────
apply_netplan() {
    local cfg="/etc/netplan/99-net-config.yaml"
    local bak="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
    [[ -f $cfg ]] && { cp "$cfg" "$bak"; info "Backup → ${bak}"; }
    info "Writing ${cfg} …"

    # On remote: always write static block (even for DHCP) as a reliable config.
    # dhcp4 flag is set to the user's choice; static address acts as fallback.
    if [[ $IP_METHOD == "dhcp" ]] && ! $IS_REMOTE; then
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
        cat > "$cfg" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: $( [[ $IP_METHOD == "dhcp" ]] && echo "true" || echo "false" )
      dhcp6: false
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
            printf '        search:\n          - %s\n' "$SEARCH_DOMAIN" >> "$cfg"
        fi
    fi

    chmod 600 "$cfg"
    netplan apply
    success "Netplan applied."
}

# ── Apply: NetworkManager ────────────────────────────────────
apply_networkmanager() {
    local CON_NAME="net-config-${IFACE}"
    info "Configuring NetworkManager …"
    nmcli con delete "$CON_NAME" &>/dev/null || true
    nmcli con delete id "$IFACE"  &>/dev/null || true

    if [[ $IP_METHOD == "dhcp" ]] && ! $IS_REMOTE; then
        nmcli con add type ethernet \
            con-name "$CON_NAME" ifname "$IFACE" \
            ipv4.method auto ipv6.method ignore
    else
        local dns_nm
        dns_nm=$(IFS=','; echo "${DNS_SERVERS[*]}")
        nmcli con add type ethernet \
            con-name       "$CON_NAME"  \
            ifname         "$IFACE"     \
            ipv4.method    $( [[ $IP_METHOD == "dhcp" ]] && echo "auto" || echo "manual" ) \
            ipv4.addresses "$STATIC_CIDR" \
            ipv4.gateway   "$GATEWAY"   \
            ipv4.dns       "$dns_nm"    \
            ipv6.method    ignore
        [[ -n ${SEARCH_DOMAIN:-} ]] && \
            nmcli con mod "$CON_NAME" ipv4.dns-search "$SEARCH_DOMAIN"
    fi

    nmcli con up "$CON_NAME"
    success "NetworkManager applied."
}

# ── Apply: /etc/network/interfaces ───────────────────────────
apply_interfaces() {
    local cfg="/etc/network/interfaces"
    local bak="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$cfg" "$bak"; info "Backup → ${bak}"
    info "Updating ${cfg} …"

    # Strip existing stanza for this interface
    python3 - "$cfg" "$IFACE" <<'PYEOF'
import sys, re
cfg_path, iface = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    content = f.read()
pattern = rf'(?m)^(allow-hotplug|auto)\s+{re.escape(iface)}\s*\n(iface\s+{re.escape(iface)}\s.*\n(?:(?!\S).*\n)*)?'
content = re.sub(pattern, '', content)
with open(cfg_path, 'w') as f:
    f.write(content.rstrip('\n') + '\n')
PYEOF

    if [[ $IP_METHOD == "dhcp" ]] && ! $IS_REMOTE; then
        printf '\nauto %s\niface %s inet dhcp\n' "$IFACE" "$IFACE" >> "$cfg"
    else
        local MASK
        MASK=$(python3 -c "
p=${CIDR_PREFIX}
m=((1<<32)-(1<<(32-p)))
print('.'.join(str((m>>(8*i))&0xff) for i in range(3,-1,-1)))")
        {
            printf '\nauto %s\n' "$IFACE"
            printf 'iface %s inet %s\n' "$IFACE" \
                "$( [[ $IP_METHOD == "dhcp" ]] && echo "dhcp" || echo "static" )"
            printf '    address         %s\n' "$STATIC_IP"
            printf '    netmask         %s\n' "$MASK"
            printf '    gateway         %s\n' "$GATEWAY"
            printf '    dns-nameservers %s\n' "${DNS_SERVERS[*]}"
            [[ -n ${SEARCH_DOMAIN:-} ]] && printf '    dns-search      %s\n' "$SEARCH_DOMAIN"
        } >> "$cfg"
    fi

    ifdown "$IFACE" 2>/dev/null || true
    ifup   "$IFACE" 2>/dev/null || systemctl restart networking 2>/dev/null || true
    success "/etc/network/interfaces updated."
}

# ── Dispatch ─────────────────────────────────────────────────
apply_hostname

case "$BACKEND" in
    netplan)        apply_netplan ;;
    networkmanager) apply_networkmanager ;;
    interfaces)     apply_interfaces ;;
    *) warn "Unknown backend — hostname was set but network config was NOT written." ;;
esac

# ── Done ─────────────────────────────────────────────────────
echo
sep
echo -e "${BOLD}${GREEN}  Configuration complete!${RESET}"
sep
info "Hostname  : ${BOLD}${NEW_HOSTNAME}${RESET}"
info "Interface : ${BOLD}${IFACE}${RESET}  →  ${IP_METHOD^^}"
$SHOW_STATIC_FIELDS && info "Address   : ${BOLD}${STATIC_CIDR}${RESET}  gw ${GATEWAY}  dns ${DNS_SERVERS[*]}"
echo
$IS_REMOTE && echo -e "${YELLOW}  To reconnect:  ssh <user>@${STATIC_IP:-<new-ip>}${RESET}\n"