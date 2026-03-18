#!/usr/bin/env bash
# =============================================================================
# setup_dev_tools.sh
# Installs/updates: Azure CLI, ripgrep, Claude Code
# Requires: Homebrew and Node.js already installed
# Compatible with macOS 10.15+ (Intel & Apple Silicon)
# Do NOT run as root — must run as the logged-in user
# =============================================================================

set -euo pipefail

LOG_FILE="/var/log/setup_dev_tools.log"

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

# ── Guard ─────────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
  log_error "This script must not run as root. Run as the logged-in user."
  exit 1
fi

# ── Ensure Homebrew is on PATH ────────────────────────────────────────────────
if [[ -x "/opt/homebrew/bin/brew" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x "/usr/local/bin/brew" ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
else
  log_error "Homebrew not found. Install Homebrew first before running this script."
  exit 1
fi

# ── Ensure npm is available ───────────────────────────────────────────────────
if ! command -v npm &>/dev/null; then
  log_error "npm not found. Ensure Node.js (v18+) is installed via Homebrew."
  exit 1
fi

# Add npm global bin to PATH
NPM_BIN="$(npm bin -g 2>/dev/null || true)"
[[ -n "$NPM_BIN" ]] && export PATH="${NPM_BIN}:$PATH"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="${TMPDIR}setup_dev_tools.log"

# =============================================================================
# 1. AZURE CLI
# =============================================================================
log_section "Step 1 — Azure CLI"

if brew list azure-cli &>/dev/null 2>&1; then
  log_ok "azure-cli already installed."
  brew upgrade azure-cli && log_ok "azure-cli upgraded." || log_warn "azure-cli already at latest version."
else
  log_info "Installing azure-cli…"
  brew install azure-cli
  log_ok "azure-cli installed: $(az version --query '"azure-cli"' -o tsv)"
fi

# =============================================================================
# 2. RIPGREP
# =============================================================================
log_section "Step 2 — ripgrep"

if brew list ripgrep &>/dev/null 2>&1; then
  log_ok "ripgrep already installed."
  brew upgrade ripgrep && log_ok "ripgrep upgraded." || log_warn "ripgrep already at latest version."
else
  log_info "Installing ripgrep…"
  brew install ripgrep
  log_ok "ripgrep installed: $(rg --version | head -1)"
fi

# =============================================================================
# 3. CLAUDE CODE
# =============================================================================
log_section "Step 3 — Claude Code"

CLAUDE_PKG="@anthropic-ai/claude-code"
BREW_PREFIX="$(brew --prefix)"
CLAUDE_BIN="${BREW_PREFIX}/bin/claude"

# Remove any stale Homebrew-placed binary/symlink that would block npm
if [[ -L "$CLAUDE_BIN" ]]; then
  LINK_TARGET="$(readlink "$CLAUDE_BIN")"
  if ! echo "$LINK_TARGET" | grep -q "node_modules"; then
    log_warn "Stale symlink at ${CLAUDE_BIN} → ${LINK_TARGET}. Removing…"
    rm -f "$CLAUDE_BIN"
    log_ok "Stale symlink removed."
  fi
elif [[ -e "$CLAUDE_BIN" ]]; then
  log_warn "Non-npm file at ${CLAUDE_BIN}. Removing…"
  brew list claude &>/dev/null 2>&1 && brew unlink claude || rm -f "$CLAUDE_BIN"
  log_ok "Removed."
fi

npm_global_version() {
  npm list -g --depth=0 "$1" 2>/dev/null \
    | grep "$1" | sed 's/.*@//' | tr -d ' ' || true
}

INSTALLED="$(npm_global_version "$CLAUDE_PKG")"
LATEST="$(npm view "$CLAUDE_PKG" version 2>/dev/null || true)"

if [[ -z "$INSTALLED" ]]; then
  log_info "Installing Claude Code…"
  npm install -g "$CLAUDE_PKG"
  log_ok "Claude Code installed: $(claude --version 2>/dev/null || echo 'open a new shell to verify')"
elif [[ -n "$LATEST" && "$INSTALLED" != "$LATEST" ]]; then
  log_info "Updating Claude Code v${INSTALLED} → v${LATEST}…"
  npm install -g "$CLAUDE_PKG"
  log_ok "Claude Code updated to v${LATEST}."
else
  log_ok "Claude Code v${INSTALLED} is already up to date."
fi

# =============================================================================
# SUMMARY
# =============================================================================
log_section "Summary"
printf "$(date '+%F %T')   %-20s %s\n" "Azure CLI"   "$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'n/a')" | tee -a "$LOG_FILE"
printf "$(date '+%F %T')   %-20s %s\n" "ripgrep"     "$(rg --version | head -1)"                                            | tee -a "$LOG_FILE"
printf "$(date '+%F %T')   %-20s %s\n" "Claude Code" "$(claude --version 2>/dev/null || echo 'open new shell to verify')"   | tee -a "$LOG_FILE"
log_ok "Done."