#!/usr/bin/env bash
# =============================================================================
# setup_dev_tools.sh
# Installs/updates: Homebrew, Azure CLI, ripgrep, Claude Code
# Compatible with macOS 10.15+ (Intel & Apple Silicon)
#
# Jamf Pro deployment pattern — LaunchAgent bootstrap
# ─────────────────────────────────────────────────────
# Jamf always runs policy scripts as root. Homebrew and npm cannot run as root.
# sudo -u requires the user to have sudo rights (not viable for standard users).
#
# Solution: when running as root this script acts as a "loader":
#   1. Writes the worker payload to /usr/local/jamf/scripts/
#   2. Writes a LaunchAgent plist to /Library/LaunchAgents/
#   3. Loads it with `launchctl bootstrap gui/<uid>` — launchd spawns the job
#      directly in the user's session with no sudo or elevated privilege needed.
#   4. The LaunchAgent self-destructs (unloads + deletes plist) on completion.
#
# Logs: /var/log/setup_dev_tools.log
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="/usr/local/jamf/scripts"
WORKER_SCRIPT="${SCRIPT_DIR}/setup_dev_tools_worker.sh"
PLIST_LABEL="com.company.setup-dev-tools"
PLIST_PATH="/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_FILE="/var/log/setup_dev_tools.log"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()    { echo -e "$(date '+%F %T') ${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
log_ok()      { echo -e "$(date '+%F %T') ${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "$(date '+%F %T') ${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE" >&2; }
log_section() {
  echo -e "\n$(date '+%F %T') ${BOLD}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "$(date '+%F %T') ${BOLD}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "$(date '+%F %T') ${BOLD}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

# =============================================================================
# ROOT BRANCH — Jamf context
# Writes the worker + LaunchAgent and bootstraps it as the console user.
# No sudo, no su, no elevated privilege required on the user side.
# =============================================================================
if [[ $EUID -eq 0 ]]; then

  # ── Identify the console user ───────────────────────────────────────────────
  CONSOLE_USER="$(stat -f '%Su' /dev/console)"
  if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
    log_error "No standard user is logged in at the console. Exiting."
    exit 1
  fi

  CONSOLE_UID="$(id -u "$CONSOLE_USER")"
  CONSOLE_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory \
                  | awk '{print $2}')"

  log_info "Console user: ${CONSOLE_USER} (uid ${CONSOLE_UID}, home ${CONSOLE_HOME})"

  # ── Touch log and make it writable by the user ─────────────────────────────
  touch "$LOG_FILE"
  chmod 666 "$LOG_FILE"

  # ── Write worker script ─────────────────────────────────────────────────────
  mkdir -p "$SCRIPT_DIR"
  chmod 755 "$SCRIPT_DIR"

  cat > "$WORKER_SCRIPT" << 'WORKER_EOF'
#!/usr/bin/env bash
# Worker — runs as console user via LaunchAgent. Never runs as root.

set -euo pipefail

LOG_FILE="/var/log/setup_dev_tools.log"
PLIST_LABEL="com.company.setup-dev-tools"
PLIST_PATH="/Library/LaunchAgents/${PLIST_LABEL}.plist"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()    { echo -e "$(date '+%F %T') ${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
log_ok()      { echo -e "$(date '+%F %T') ${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "$(date '+%F %T') ${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE" >&2; }
log_section() {
  echo -e "\n$(date '+%F %T') ${BOLD}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "$(date '+%F %T') ${BOLD}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "$(date '+%F %T') ${BOLD}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

export NONINTERACTIVE=1
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

# ===========================================================================
# 1. HOMEBREW
# ===========================================================================
log_section "Step 1 — Homebrew"

if command -v brew &>/dev/null; then
  log_ok "Homebrew already installed at $(brew --prefix)"
  log_info "Updating Homebrew…"
  brew update
  log_ok "Homebrew updated."
else
  log_info "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  log_ok "Homebrew installed."
fi

# ===========================================================================
# 2. AZURE CLI
# ===========================================================================
log_section "Step 2 — Azure CLI"

if brew list azure-cli &>/dev/null 2>&1; then
  log_ok "azure-cli already installed."
  brew upgrade azure-cli || log_warn "azure-cli already at latest version."
else
  log_info "Installing azure-cli…"
  brew install azure-cli
  log_ok "azure-cli installed."
fi

# ===========================================================================
# 3. RIPGREP
# ===========================================================================
log_section "Step 3 — ripgrep"

if brew list ripgrep &>/dev/null 2>&1; then
  log_ok "ripgrep already installed."
  brew upgrade ripgrep || log_warn "ripgrep already at latest version."
else
  log_info "Installing ripgrep…"
  brew install ripgrep
  log_ok "ripgrep installed."
fi

# ===========================================================================
# 4. NODE.JS
# ===========================================================================
log_section "Step 4a — Node.js"

NODE_MIN=18

install_or_upgrade_node() {
  if brew list node &>/dev/null 2>&1; then
    brew upgrade node || log_warn "Node.js already at latest version."
  else
    brew install node
  fi
}

if command -v node &>/dev/null; then
  NODE_MAJOR=$(node --version | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_MAJOR" -ge "$NODE_MIN" ]]; then
    log_ok "Node.js $(node --version) meets requirement (v${NODE_MIN}+)."
  else
    log_warn "Node.js $(node --version) is too old. Upgrading…"
    install_or_upgrade_node
  fi
else
  log_info "Node.js not found. Installing…"
  install_or_upgrade_node
fi

NPM_BIN="$(npm bin -g 2>/dev/null || true)"
[[ -n "$NPM_BIN" ]] && export PATH="${NPM_BIN}:$PATH"
log_ok "Node.js $(node --version) | npm $(npm --version)"

# ===========================================================================
# 5. CLAUDE CODE
# ===========================================================================
log_section "Step 4b — Claude Code"

CLAUDE_PKG="@anthropic-ai/claude-code"
BREW_PREFIX="$(brew --prefix)"
CLAUDE_BIN="${BREW_PREFIX}/bin/claude"

# Stale symlink / orphaned binary cleanup
if [[ -e "$CLAUDE_BIN" || -L "$CLAUDE_BIN" ]]; then
  if [[ -L "$CLAUDE_BIN" ]]; then
    LINK_TARGET="$(readlink "$CLAUDE_BIN")"
    if echo "$LINK_TARGET" | grep -q "node_modules"; then
      log_ok "Existing claude symlink is npm-managed — no cleanup needed."
    else
      log_warn "Stale symlink at ${CLAUDE_BIN} → ${LINK_TARGET}. Removing…"
      rm -f "$CLAUDE_BIN"
      log_ok "Stale symlink removed."
    fi
  else
    log_warn "Non-symlink file at ${CLAUDE_BIN}. Removing…"
    if brew list claude &>/dev/null 2>&1; then
      brew unlink claude && log_ok "Unlinked Homebrew claude formula."
    else
      rm -f "$CLAUDE_BIN" && log_ok "Removed orphaned binary."
    fi
  fi
fi

npm_global_version() {
  npm list -g --depth=0 "$1" 2>/dev/null \
    | grep "$1" | sed 's/.*@//' | tr -d ' ' || true
}

INSTALLED="$(npm_global_version "$CLAUDE_PKG")"
LATEST="$(npm view "$CLAUDE_PKG" version 2>/dev/null || true)"

if [[ -z "$INSTALLED" ]]; then
  log_info "Installing ${CLAUDE_PKG}…"
  npm install -g "$CLAUDE_PKG"
  log_ok "Claude Code installed: $(claude --version 2>/dev/null || echo 'open new shell to verify')"
elif [[ -n "$LATEST" && "$INSTALLED" != "$LATEST" ]]; then
  log_info "Updating Claude Code v${INSTALLED} → v${LATEST}…"
  npm install -g "$CLAUDE_PKG"
  log_ok "Claude Code updated to v${LATEST}."
else
  log_ok "Claude Code v${INSTALLED} is already up to date."
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
log_section "Installation Summary"
printf "$(date '+%F %T')   %-20s %s\n" "Homebrew"    "$(brew --version | head -1)"                                          | tee -a "$LOG_FILE"
printf "$(date '+%F %T')   %-20s %s\n" "Azure CLI"   "$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'n/a')" | tee -a "$LOG_FILE"
printf "$(date '+%F %T')   %-20s %s\n" "ripgrep"     "$(rg --version | head -1)"                                            | tee -a "$LOG_FILE"
printf "$(date '+%F %T')   %-20s %s\n" "Node.js"     "$(node --version)"                                                    | tee -a "$LOG_FILE"
printf "$(date '+%F %T')   %-20s %s\n" "npm"         "$(npm --version)"                                                     | tee -a "$LOG_FILE"
printf "$(date '+%F %T')   %-20s %s\n" "Claude Code" "$(claude --version 2>/dev/null || echo 'open new shell')"             | tee -a "$LOG_FILE"
log_ok "All tools installed and up to date."

# ===========================================================================
# SELF-DESTRUCT — unload and remove LaunchAgent so it never re-fires
# ===========================================================================
SELF_UID="$(id -u)"
launchctl bootout "gui/${SELF_UID}/${PLIST_LABEL}" 2>/dev/null || true
rm -f "$PLIST_PATH"
log_info "LaunchAgent removed. Done."
WORKER_EOF

  chmod 755 "$WORKER_SCRIPT"
  chown root "$WORKER_SCRIPT"

  # ── Write the LaunchAgent plist ─────────────────────────────────────────────
  cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WORKER_SCRIPT}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <false/>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${CONSOLE_HOME}</string>
    <key>NONINTERACTIVE</key>
    <string>1</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>

  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST_EOF

  chmod 644 "$PLIST_PATH"
  chown root "$PLIST_PATH"

  # ── Bootstrap into the user's gui session ───────────────────────────────────
  # launchctl bootstrap loads the agent into the user's launchd session and
  # fires it immediately. The user needs zero privileges for this to work —
  # root is loading on their behalf.
  log_info "Bootstrapping LaunchAgent for '${CONSOLE_USER}'…"
  launchctl bootstrap "gui/${CONSOLE_UID}" "$PLIST_PATH"
  log_ok "LaunchAgent loaded. Worker is running as '${CONSOLE_USER}'."
  log_info "Monitor progress:  tail -f ${LOG_FILE}"

  exit 0
fi

# =============================================================================
# USER BRANCH — direct / manual execution (not via Jamf)
# Reached only when the script is run directly as a normal user.
# =============================================================================

export NONINTERACTIVE=1
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

log_section "Step 1 — Homebrew"
if command -v brew &>/dev/null; then
  log_ok "Homebrew already installed at $(brew --prefix)"
  brew update && log_ok "Homebrew updated."
else
  log_info "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  [[ -x "/opt/homebrew/bin/brew" ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [[ -x "/usr/local/bin/brew" ]]    && eval "$(/usr/local/bin/brew shellenv)"
  log_ok "Homebrew installed."
fi

log_section "Step 2 — Azure CLI"
if brew list azure-cli &>/dev/null 2>&1; then
  brew upgrade azure-cli || log_warn "azure-cli already at latest."
else
  brew install azure-cli && log_ok "azure-cli installed."
fi

log_section "Step 3 — ripgrep"
if brew list ripgrep &>/dev/null 2>&1; then
  brew upgrade ripgrep || log_warn "ripgrep already at latest."
else
  brew install ripgrep && log_ok "ripgrep installed."
fi

log_section "Step 4a — Node.js"
NODE_MIN=18
install_or_upgrade_node() {
  brew list node &>/dev/null 2>&1 && brew upgrade node || brew install node
}
if command -v node &>/dev/null; then
  NODE_MAJOR=$(node --version | sed 's/v//' | cut -d. -f1)
  [[ "$NODE_MAJOR" -lt "$NODE_MIN" ]] && install_or_upgrade_node \
    || log_ok "Node.js $(node --version) OK."
else
  install_or_upgrade_node
fi
NPM_BIN="$(npm bin -g 2>/dev/null || true)"
[[ -n "$NPM_BIN" ]] && export PATH="${NPM_BIN}:$PATH"

log_section "Step 4b — Claude Code"
CLAUDE_PKG="@anthropic-ai/claude-code"
BREW_PREFIX="$(brew --prefix)"
CLAUDE_BIN="${BREW_PREFIX}/bin/claude"
if [[ -L "$CLAUDE_BIN" ]]; then
  LINK_TARGET="$(readlink "$CLAUDE_BIN")"
  echo "$LINK_TARGET" | grep -q "node_modules" || rm -f "$CLAUDE_BIN"
elif [[ -e "$CLAUDE_BIN" ]]; then
  brew list claude &>/dev/null 2>&1 && brew unlink claude || rm -f "$CLAUDE_BIN"
fi
npm_global_version() {
  npm list -g --depth=0 "$1" 2>/dev/null | grep "$1" | sed 's/.*@//' | tr -d ' ' || true
}
INSTALLED="$(npm_global_version "$CLAUDE_PKG")"
LATEST="$(npm view "$CLAUDE_PKG" version 2>/dev/null || true)"
if [[ -z "$INSTALLED" ]]; then
  npm install -g "$CLAUDE_PKG" && log_ok "Claude Code installed."
elif [[ -n "$LATEST" && "$INSTALLED" != "$LATEST" ]]; then
  npm install -g "$CLAUDE_PKG" && log_ok "Claude Code updated to v${LATEST}."
else
  log_ok "Claude Code v${INSTALLED} is up to date."
fi

log_section "Summary"
printf "  %-20s %s\n" "Homebrew"    "$(brew --version | head -1)"
printf "  %-20s %s\n" "Azure CLI"   "$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'n/a')"
printf "  %-20s %s\n" "ripgrep"     "$(rg --version | head -1)"
printf "  %-20s %s\n" "Node.js"     "$(node --version)"
printf "  %-20s %s\n" "npm"         "$(npm --version)"
printf "  %-20s %s\n" "Claude Code" "$(claude --version 2>/dev/null || echo 'open new shell')"
log_ok "All tools installed and up to date."