#!/bin/bash
# ============================================================
#  net-config.sh  Network & Hostname Configurator
#  Pre-fills every prompt from current live settings.
#  On SSH sessions: always shows all IP fields.
#
#  Supports: Netplan, NetworkManager, /etc/network/interfaces
#  Usage: sudo bash net-config.sh
# ============================================================

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
sep()     { echo -e "${DIM}----------------------------------------------------${RESET}"; }

# Force stdin from terminal so read always waits for user input
# (handles curl|bash, piped installs, and some sudo configurations)
exec < /dev/tty

# ── Root check ───────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    die "Run as root:  sudo $0"
fi

# ── Detect SSH session ───────────────────────────────────────
IS_REMOTE="false"
if [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
    IS_REMOTE="true"
fi

# ── Detect network backend ───────────────────────────────────
detect_backend() {
    if command -v netplan > /dev/null 2>&1; then
        if ls /etc/netplan/*.yaml > /dev/null 2>&1; then
            echo "netplan"
            return
        fi
    fi
    if command -v nmcli > /dev/null 2>&1; then
        echo "networkmanager"
        return
    fi
    if [ -f /etc/network/interfaces ]; then
        echo "interfaces"
        return
    fi
    echo "unknown"
}

BACKEND=$(detect_backend)

# ── Banner ───────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "==========================================================="
echo "          Linux Network Configuration Utility"
echo "==========================================================="
echo -e "${RESET}"
info "Network backend: ${BOLD}${BACKEND}${RESET}"
echo

if [ "$IS_REMOTE" = "true" ]; then
    echo -e "${YELLOW}${BOLD}  WARNING: Remote/SSH session detected.${RESET}"
    echo -e "${YELLOW}  All fields will be prompted, including static IP.${RESET}"
    echo -e "${YELLOW}  Changing the IP address WILL drop this connection.${RESET}"
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
    DNS_OUT=""
    if command -v resolvectl > /dev/null 2>&1; then
        DNS_OUT=$(resolvectl status 2>/dev/null | awk '/DNS Servers/{for(i=3;i<=NF;i++) printf $i" "; print ""}' | head -1 | xargs 2>/dev/null)
    fi
    if [ -z "$DNS_OUT" ] && [ -f /etc/resolv.conf ]; then
        DNS_OUT=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf | xargs 2>/dev/null)
    fi
    echo "$DNS_OUT"
}

get_current_search() {
    awk '/^search/{$1=""; print; exit}' /etc/resolv.conf 2>/dev/null | xargs 2>/dev/null
}

is_dhcp() {
    IFACE_CHECK="$1"
    case "$BACKEND" in
        netplan)
            if grep -rl "dhcp4: true" /etc/netplan/ 2>/dev/null | grep -q "$IFACE_CHECK" 2>/dev/null; then
                echo "dhcp"
            else
                echo "static"
            fi
            ;;
        networkmanager)
            CON_ID=$(nmcli -g GENERAL.CONNECTION dev show "$IFACE_CHECK" 2>/dev/null || echo "")
            if [ -n "$CON_ID" ]; then
                METHOD=$(nmcli -g ipv4.method con show "$CON_ID" 2>/dev/null || echo "")
                if [ "$METHOD" = "auto" ]; then
                    echo "dhcp"
                else
                    echo "static"
                fi
            else
                echo "dhcp"
            fi
            ;;
        interfaces)
            if grep -A5 "iface $IFACE_CHECK" /etc/network/interfaces 2>/dev/null | grep -q "inet dhcp"; then
                echo "dhcp"
            else
                echo "static"
            fi
            ;;
        *)
            echo "dhcp"
            ;;
    esac
}

cidr_to_mask() {
    P="$1"
    M=""
    I=0
    while [ "$I" -lt 4 ]; do
        if [ "$I" -lt $(( P / 8 )) ]; then
            M="${M}255"
        elif [ "$I" -eq $(( P / 8 )) ]; then
            M="${M}$(( 256 - (1 << (8 - P % 8)) ))"
        else
            M="${M}0"
        fi
        if [ "$I" -lt 3 ]; then M="${M}."; fi
        I=$(( I + 1 ))
    done
    echo "$M"
}

mask_to_cidr() {
    MASK="$1"
    CIDR=0
    IFS='.' read -r O1 O2 O3 O4 << EOF
$MASK
EOF
    for OCT in $O1 $O2 $O3 $O4; do
        BITS=8
        while [ "$BITS" -gt 0 ]; do
            BITS=$(( BITS - 1 ))
            if [ $(( (OCT >> BITS) & 1 )) -eq 1 ]; then
                CIDR=$(( CIDR + 1 ))
            else
                BITS=0
            fi
        done
    done
    echo "$CIDR"
}

validate_ip() {
    V_IP="$1"
    IFS='.' read -r A B C D << EOF
$V_IP
EOF
    if [ -z "$A" ] || [ -z "$B" ] || [ -z "$C" ] || [ -z "$D" ]; then
        return 1
    fi
    for SEG in $A $B $C $D; do
        case "$SEG" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "$SEG" -lt 0 ] || [ "$SEG" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

# ── Prompt helper ─────────────────────────────────────────────
# prompt_field VARNAME "Label" "current value"
# Shows existing value in brackets, Enter keeps it.
prompt_field() {
    PF_VAR="$1"
    PF_LABEL="$2"
    PF_CURRENT="$3"
    PF_INPUT=""

    while true; do
        if [ -n "$PF_CURRENT" ]; then
            echo -ne "${BOLD}  ${PF_LABEL}${RESET} ${DIM}[${PF_CURRENT}]${RESET}: "
        else
            echo -ne "${BOLD}  ${PF_LABEL}${RESET}: "
        fi

        read -r PF_INPUT </dev/tty || PF_INPUT=""

        if [ -z "$PF_INPUT" ]; then
            PF_INPUT="$PF_CURRENT"
        fi

        if [ -z "$PF_INPUT" ]; then
            warn "  This field cannot be empty."
        else
            eval "${PF_VAR}=\"\${PF_INPUT}\""
            return 0
        fi
    done
}

# ============================================================
# STEP 1 - Hostname
# ============================================================
echo -e "${BOLD}-- Step 1: Hostname ------------------------------------------${RESET}"
CURRENT_HOSTNAME=$(hostname)
prompt_field "NEW_HOSTNAME" "Hostname" "$CURRENT_HOSTNAME"

# Validate hostname characters (POSIX-safe check)
HOSTNAME_INVALID=$(echo "$NEW_HOSTNAME" | tr -d 'a-zA-Z0-9-')
if [ -n "$HOSTNAME_INVALID" ]; then
    die "Invalid hostname '$NEW_HOSTNAME'. Use only letters, numbers, and hyphens."
fi
echo

# ============================================================
# STEP 2 - Interface selection
# ============================================================
echo -e "${BOLD}-- Step 2: Network Interface ---------------------------------${RESET}"
IFACES_RAW=$(get_interfaces)
if [ -z "$IFACES_RAW" ]; then
    die "No network interfaces found."
fi

# Build arrays manually (POSIX-safe)
IDX=0
for IFC in $IFACES_RAW; do
    IDX=$(( IDX + 1 ))
    eval "IFACE_${IDX}=${IFC}"
done
IFACE_COUNT="$IDX"

# Detect active SSH interface
DEFAULT_IFACE_IDX=1
if [ "$IS_REMOTE" = "true" ] && [ -n "${SSH_CONNECTION:-}" ]; then
    SSH_LOCAL_IP=$(echo "$SSH_CONNECTION" | awk '{print $3}')
    IDX=0
    for IFC in $IFACES_RAW; do
        IDX=$(( IDX + 1 ))
        if ip -4 addr show "$IFC" 2>/dev/null | grep -q "$SSH_LOCAL_IP"; then
            DEFAULT_IFACE_IDX="$IDX"
            break
        fi
    done
fi

echo "  Available interfaces:"
IDX=0
for IFC in $IFACES_RAW; do
    IDX=$(( IDX + 1 ))
    CUR_IP_SHOW=$(get_current_ip "$IFC")
    CUR_PFX_SHOW=$(get_current_prefix "$IFC")
    METHOD_SHOW=$(is_dhcp "$IFC")
    ACTIVE_NOTE=""
    if [ "$IS_REMOTE" = "true" ] && [ "$IDX" -eq "$DEFAULT_IFACE_IDX" ]; then
        ACTIVE_NOTE="  <-- active SSH interface"
    fi
    ADDR_SHOW=""
    if [ -n "$CUR_IP_SHOW" ]; then
        ADDR_SHOW="${CUR_IP_SHOW}/${CUR_PFX_SHOW}"
    fi
    printf "    ${CYAN}%d)${RESET} %-14s %-22s (%s)%s\n" \
        "$IDX" "$IFC" "$ADDR_SHOW" "${METHOD_SHOW}" "$ACTIVE_NOTE"
done
echo

while true; do
    prompt_field "IFACE_CHOICE" "Select interface number" "$DEFAULT_IFACE_IDX"
    IFACE_CHOICE_VALID=$(echo "$IFACE_CHOICE" | tr -d '0-9')
    if [ -n "$IFACE_CHOICE_VALID" ] || [ "$IFACE_CHOICE" -lt 1 ] || [ "$IFACE_CHOICE" -gt "$IFACE_COUNT" ]; then
        warn "  Enter a number between 1 and ${IFACE_COUNT}."
    else
        break
    fi
done

eval "IFACE=\${IFACE_${IFACE_CHOICE}}"

# Gather current values for selected interface
CUR_IP=$(get_current_ip "$IFACE")
CUR_PREFIX=$(get_current_prefix "$IFACE")
CUR_MASK=""
if [ -n "$CUR_PREFIX" ]; then
    CUR_MASK=$(cidr_to_mask "$CUR_PREFIX")
fi
CUR_GW=$(get_current_gateway)
CUR_DNS=$(get_current_dns)
CUR_SEARCH=$(get_current_search)
CUR_METHOD=$(is_dhcp "$IFACE")

info "Selected: ${BOLD}${IFACE}${RESET} (currently ${CUR_METHOD} - ${CUR_IP:-no IP})"
echo

# ============================================================
# STEP 3 - DHCP or Static
# ============================================================
echo -e "${BOLD}-- Step 3: IP Address Method ---------------------------------${RESET}"

while true; do
    prompt_field "IP_METHOD" "Method (dhcp or static)" "$CUR_METHOD"
    IP_METHOD=$(echo "$IP_METHOD" | tr '[:upper:]' '[:lower:]')
    if [ "$IP_METHOD" = "dhcp" ] || [ "$IP_METHOD" = "static" ]; then
        break
    fi
    warn "  Please enter 'dhcp' or 'static'."
done
echo

# ============================================================
# STEP 4 - IP address fields
# Always shown for static. Always shown when on SSH.
# ============================================================
SHOW_STATIC_FIELDS="false"
if [ "$IP_METHOD" = "static" ]; then
    SHOW_STATIC_FIELDS="true"
fi
if [ "$IS_REMOTE" = "true" ]; then
    SHOW_STATIC_FIELDS="true"
fi

if [ "$SHOW_STATIC_FIELDS" = "true" ]; then
    echo -e "${BOLD}-- Step 4: IP Address Details --------------------------------${RESET}"

    if [ "$IS_REMOTE" = "true" ] && [ "$IP_METHOD" = "dhcp" ]; then
        echo -e "  ${YELLOW}You chose DHCP. These values are written as a static${RESET}"
        echo -e "  ${YELLOW}fallback so you can reconnect if DHCP fails.${RESET}"
        echo
    fi

    # IP Address
    while true; do
        prompt_field "STATIC_IP" "IP Address" "${CUR_IP:-}"
        if validate_ip "$STATIC_IP"; then
            break
        fi
        warn "  Not a valid IPv4 address (e.g. 192.168.1.100)."
    done

    # Subnet mask or prefix
    SUBNET_DEFAULT="${CUR_MASK:-${CUR_PREFIX:-24}}"
    while true; do
        prompt_field "SUBNET_INPUT" "Subnet Mask or prefix (e.g. 255.255.255.0 or 24)" "$SUBNET_DEFAULT"
        IS_PURE_NUM=$(echo "$SUBNET_INPUT" | tr -d '0-9')
        if [ -z "$IS_PURE_NUM" ] && [ "$SUBNET_INPUT" -ge 0 ] && [ "$SUBNET_INPUT" -le 32 ]; then
            CIDR_PREFIX="$SUBNET_INPUT"
            break
        elif validate_ip "$SUBNET_INPUT"; then
            CIDR_PREFIX=$(mask_to_cidr "$SUBNET_INPUT")
            break
        fi
        warn "  Enter a dotted mask (255.255.255.0) or prefix length (24)."
    done
    STATIC_CIDR="${STATIC_IP}/${CIDR_PREFIX}"

    # Gateway
    while true; do
        prompt_field "GATEWAY" "Default Gateway" "${CUR_GW:-}"
        if validate_ip "$GATEWAY"; then
            break
        fi
        warn "  Not a valid IPv4 address."
    done

    # DNS servers
    echo -e "  ${DIM}(Space-separated for multiple, e.g. 8.8.8.8 1.1.1.1)${RESET}"
    DNS_DEFAULT="${CUR_DNS:-8.8.8.8 8.8.4.4}"
    while true; do
        prompt_field "DNS_INPUT" "DNS Server(s)" "$DNS_DEFAULT"
        DNS_VALID="true"
        for DNS_ENTRY in $DNS_INPUT; do
            if ! validate_ip "$DNS_ENTRY"; then
                warn "  '$DNS_ENTRY' is not a valid IP address."
                DNS_VALID="false"
                break
            fi
        done
        if [ "$DNS_VALID" = "true" ]; then
            break
        fi
    done

    # Search domain (optional)
    SEARCH_DEFAULT="${CUR_SEARCH:-}"
    prompt_field "SEARCH_DOMAIN" "DNS Search Domain (blank to skip)" "$SEARCH_DEFAULT"
    if [ "$SEARCH_DOMAIN" = "none" ] || [ "$SEARCH_DOMAIN" = "-" ]; then
        SEARCH_DOMAIN=""
    fi
    echo
fi

# ============================================================
# STEP 5 - Confirm
# ============================================================
sep
echo -e "${BOLD}  Review changes${RESET}"
sep
printf "  %-20s %s  -->  %s\n" "Hostname:"  "$CURRENT_HOSTNAME"  "$NEW_HOSTNAME"
printf "  %-20s %s\n"          "Interface:" "$IFACE"
printf "  %-20s %s  -->  %s\n" "Method:"    "$CUR_METHOD"        "$IP_METHOD"

if [ "$SHOW_STATIC_FIELDS" = "true" ]; then
    OLD_CIDR="${CUR_IP:-?}/${CUR_PREFIX:-?}"
    printf "  %-20s %s  -->  %s\n" "IP/CIDR:"      "$OLD_CIDR"     "$STATIC_CIDR"
    printf "  %-20s %s  -->  %s\n" "Gateway:"       "${CUR_GW:-?}" "$GATEWAY"
    printf "  %-20s %s  -->  %s\n" "DNS:"           "${CUR_DNS:-?}" "$DNS_INPUT"
    if [ -n "${SEARCH_DOMAIN:-}" ]; then
        printf "  %-20s %s  -->  %s\n" "Search Domain:" "${CUR_SEARCH:-?}" "$SEARCH_DOMAIN"
    fi
fi
sep
echo

if [ "$IS_REMOTE" = "true" ]; then
    echo -e "${RED}${BOLD}  WARNING: You are on a remote/SSH session.${RESET}"
    if [ "$SHOW_STATIC_FIELDS" = "true" ]; then
        echo -e "${RED}  If the IP changes, reconnect with: ssh <user>@${STATIC_IP:-?}${RESET}"
    fi
    echo
fi

echo -ne "${YELLOW}${BOLD}  Apply these settings? [y/N]: ${RESET}"
read -r CONFIRM </dev/tty || CONFIRM=""
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
    info "Aborted -- no changes written."
    exit 0
fi
echo

# ============================================================
# Apply: Hostname
# ============================================================
apply_hostname() {
    info "Setting hostname to '${NEW_HOSTNAME}' ..."
    echo "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME"
    # Replace old hostname in /etc/hosts
    sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
    # Ensure 127.0.1.1 entry
    if ! grep -q "127.0.1.1" /etc/hosts; then
        echo "127.0.1.1  ${NEW_HOSTNAME}" >> /etc/hosts
    fi
    success "Hostname updated."
}

# ============================================================
# Apply: Netplan
# ============================================================
apply_netplan() {
    CFG="/etc/netplan/99-net-config.yaml"
    BAK="${CFG}.bak.$(date +%Y%m%d%H%M%S)"
    if [ -f "$CFG" ]; then
        cp "$CFG" "$BAK"
        info "Backup: ${BAK}"
    fi
    info "Writing ${CFG} ..."

    if [ "$IP_METHOD" = "dhcp" ] && [ "$IS_REMOTE" = "false" ]; then
        cat > "$CFG" << YAMLEOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: true
      dhcp6: false
YAMLEOF
    else
        DHCP_FLAG="false"
        if [ "$IP_METHOD" = "dhcp" ]; then
            DHCP_FLAG="true"
        fi

        {
            printf 'network:\n'
            printf '  version: 2\n'
            printf '  renderer: networkd\n'
            printf '  ethernets:\n'
            printf '    %s:\n'              "$IFACE"
            printf '      dhcp4: %s\n'     "$DHCP_FLAG"
            printf '      dhcp6: false\n'
            printf '      addresses:\n'
            printf '        - %s\n'         "$STATIC_CIDR"
            printf '      routes:\n'
            printf '        - to: default\n'
            printf '          via: %s\n'    "$GATEWAY"
            printf '      nameservers:\n'
            printf '        addresses:\n'
            for DNS_ENTRY in $DNS_INPUT; do
                printf '          - %s\n'  "$DNS_ENTRY"
            done
            if [ -n "${SEARCH_DOMAIN:-}" ]; then
                printf '        search:\n'
                printf '          - %s\n'  "$SEARCH_DOMAIN"
            fi
        } > "$CFG"
    fi

    chmod 600 "$CFG"
    netplan apply
    success "Netplan applied."
}

# ============================================================
# Apply: NetworkManager
# ============================================================
apply_networkmanager() {
    CON_NAME="net-config-${IFACE}"
    info "Configuring via NetworkManager ..."

    nmcli con delete "$CON_NAME"  > /dev/null 2>&1 || true
    nmcli con delete id "$IFACE"  > /dev/null 2>&1 || true

    if [ "$IP_METHOD" = "dhcp" ] && [ "$IS_REMOTE" = "false" ]; then
        nmcli con add type ethernet \
            con-name "$CON_NAME" \
            ifname   "$IFACE"    \
            ipv4.method auto     \
            ipv6.method ignore
    else
        NM_METHOD="manual"
        if [ "$IP_METHOD" = "dhcp" ]; then
            NM_METHOD="auto"
        fi
        DNS_NM=$(echo "$DNS_INPUT" | tr ' ' ',')
        nmcli con add type ethernet \
            con-name       "$CON_NAME"   \
            ifname         "$IFACE"      \
            ipv4.method    "$NM_METHOD"  \
            ipv4.addresses "$STATIC_CIDR" \
            ipv4.gateway   "$GATEWAY"    \
            ipv4.dns       "$DNS_NM"     \
            ipv6.method    ignore
        if [ -n "${SEARCH_DOMAIN:-}" ]; then
            nmcli con mod "$CON_NAME" ipv4.dns-search "$SEARCH_DOMAIN"
        fi
    fi

    nmcli con up "$CON_NAME"
    success "NetworkManager applied."
}

# ============================================================
# Apply: /etc/network/interfaces
# ============================================================
apply_interfaces() {
    CFG="/etc/network/interfaces"
    BAK="${CFG}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CFG" "$BAK"
    info "Backup: ${BAK}"
    info "Updating ${CFG} ..."

    python3 - "$CFG" "$IFACE" << 'PYEOF'
import sys, re
cfg_path, iface = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    content = f.read()
pattern = r'(?m)^(allow-hotplug|auto)\s+' + re.escape(iface) + r'\s*\n(iface\s+' + re.escape(iface) + r'\s.*\n(?:(?!\S).*\n)*)?'
content = re.sub(pattern, '', content)
with open(cfg_path, 'w') as f:
    f.write(content.rstrip('\n') + '\n')
PYEOF

    if [ "$IP_METHOD" = "dhcp" ] && [ "$IS_REMOTE" = "false" ]; then
        printf '\nauto %s\niface %s inet dhcp\n' "$IFACE" "$IFACE" >> "$CFG"
    else
        MASK_OUT=$(python3 -c "
p=int('${CIDR_PREFIX}')
m=((1<<32)-(1<<(32-p)))
print('.'.join(str((m>>(8*i))&0xff) for i in range(3,-1,-1)))")
        INET_TYPE="static"
        if [ "$IP_METHOD" = "dhcp" ]; then
            INET_TYPE="dhcp"
        fi
        {
            printf '\nauto %s\n'              "$IFACE"
            printf 'iface %s inet %s\n'      "$IFACE" "$INET_TYPE"
            printf '    address         %s\n' "$STATIC_IP"
            printf '    netmask         %s\n' "$MASK_OUT"
            printf '    gateway         %s\n' "$GATEWAY"
            printf '    dns-nameservers %s\n' "$DNS_INPUT"
            if [ -n "${SEARCH_DOMAIN:-}" ]; then
                printf '    dns-search      %s\n' "$SEARCH_DOMAIN"
            fi
        } >> "$CFG"
    fi

    ifdown "$IFACE" > /dev/null 2>&1 || true
    ifup   "$IFACE" > /dev/null 2>&1 || systemctl restart networking > /dev/null 2>&1 || true
    success "/etc/network/interfaces updated."
}

# ============================================================
# Dispatch
# ============================================================
apply_hostname

case "$BACKEND" in
    netplan)        apply_netplan ;;
    networkmanager) apply_networkmanager ;;
    interfaces)     apply_interfaces ;;
    *)
        echo -e "${YELLOW}[WARN]${RESET}  Unknown backend -- hostname was updated but network config was NOT written."
        ;;
esac

# ============================================================
# Done
# ============================================================
echo
sep
echo -e "${BOLD}${GREEN}  Configuration complete!${RESET}"
sep
info "Hostname  : ${BOLD}${NEW_HOSTNAME}${RESET}"
info "Interface : ${BOLD}${IFACE}${RESET}  (${IP_METHOD})"
if [ "$SHOW_STATIC_FIELDS" = "true" ]; then
    info "Address   : ${BOLD}${STATIC_CIDR}${RESET}  gw ${GATEWAY}  dns ${DNS_INPUT}"
fi
echo
if [ "$IS_REMOTE" = "true" ] && [ -n "${STATIC_IP:-}" ]; then
    echo -e "${YELLOW}  To reconnect: ssh <user>@${STATIC_IP}${RESET}"
    echo
fi