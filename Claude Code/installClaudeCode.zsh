#!/usr/bin/env bash
# =============================================================================
# setup_dev_tools.sh
# Installs/updates: Homebrew, Azure CLI, ripgrep, Claude Code
# Compatible with macOS 10.15+ (Intel & Apple Silicon)
#
# Jamf Pro note: policy scripts always execute as root. This script detects
# that condition and re-launches itself as the current console user via
# launchctl asuser + sudo -u, which gives Homebrew and npm the correct user
# environment (HOME, PATH, npm prefix) they require.
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}══════════════════════════════════════════${RESET}"; \
                echo -e "${BOLD}  $*${RESET}"; \
                echo -e "${BOLD}══════════════════════════════════════════${RESET}"; }

# ── Jamf-aware root re-exec ───────────────────────────────────────────────────
# Jamf Pro runs all policy scripts as root regardless of the "Run As" setting.
# Homebrew and npm global installs must run as the logged-in user.
# If we are root, find the current console user, then re-execute this entire
# script as that user using launchctl asuser (which loads the user's launchd
# session, giving access to the correct PATH, HOME, and environment).
if [[ $EUID -eq 0 ]]; then
  CONSOLE_USER="$(stat -f '%Su' /dev/console)"

  if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
    log_error "No standard user is logged in at the console. Cannot continue."
    log_error "Log in as a non-root user and re-run this policy."
    exit 1
  fi

  CONSOLE_UID="$(id -u "$CONSOLE_USER")"
  log_info "Running as root — re-launching as console user '${CONSOLE_USER}' (uid ${CONSOLE_UID})…"

  # launchctl asuser loads the user's login session; sudo -u runs the command
  # as that user within that session, preserving HOME and environment.
  exec launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" bash "$0" "$@"
fi

# ── From this point the script is guaranteed to run as a normal user ──────────

# =============================================================================
# 1. HOMEBREW
# =============================================================================
log_section "Step 1 — Homebrew"

if command -v brew &>/dev/null; then
  log_ok "Homebrew already installed at $(brew --prefix)"
  log_info "Updating Homebrew…"
  brew update
  log_ok "Homebrew is up to date."
else
  log_info "Homebrew not found. Installing…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add Homebrew to PATH for the remainder of this script (Apple Silicon default path)
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  log_ok "Homebrew installed successfully."
fi

# =============================================================================
# 2. AZURE CLI
# =============================================================================
log_section "Step 2 — Azure CLI"

if brew list azure-cli &>/dev/null 2>&1; then
  log_ok "azure-cli already installed ($(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'version unknown'))."
  log_info "Upgrading azure-cli if a newer version is available…"
  brew upgrade azure-cli || log_warn "azure-cli is already at the latest version."
else
  log_info "Installing azure-cli via Homebrew…"
  brew install azure-cli
  log_ok "azure-cli installed: $(az version --query '"azure-cli"' -o tsv)"
fi

# =============================================================================
# 3. RIPGREP
# =============================================================================
log_section "Step 3 — ripgrep"

if brew list ripgrep &>/dev/null 2>&1; then
  log_ok "ripgrep already installed ($(rg --version | head -1))."
  log_info "Upgrading ripgrep if a newer version is available…"
  brew upgrade ripgrep || log_warn "ripgrep is already at the latest version."
else
  log_info "Installing ripgrep via Homebrew…"
  brew install ripgrep
  log_ok "ripgrep installed: $(rg --version | head -1)"
fi

# =============================================================================
# 4. NODE.JS (prerequisite for Claude Code)
# =============================================================================
log_section "Step 4a — Node.js (prerequisite for Claude Code)"

NODE_MIN_VERSION=18

install_or_upgrade_node() {
  if brew list node &>/dev/null 2>&1; then
    log_info "Upgrading Node.js…"
    brew upgrade node || log_warn "Node.js is already at the latest version."
  else
    log_info "Installing Node.js via Homebrew…"
    brew install node
  fi
}

if command -v node &>/dev/null; then
  NODE_VERSION=$(node --version | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_VERSION" -ge "$NODE_MIN_VERSION" ]]; then
    log_ok "Node.js $(node --version) satisfies the minimum requirement (v${NODE_MIN_VERSION}+)."
  else
    log_warn "Node.js $(node --version) is below v${NODE_MIN_VERSION}. Upgrading…"
    install_or_upgrade_node
  fi
else
  log_info "Node.js not found. Installing…"
  install_or_upgrade_node
fi

# Ensure the Homebrew-managed npm bin directory is in PATH
NPM_BIN_DIR="$(npm bin -g 2>/dev/null || true)"
if [[ -n "$NPM_BIN_DIR" && ":$PATH:" != *":$NPM_BIN_DIR:"* ]]; then
  export PATH="$NPM_BIN_DIR:$PATH"
fi

log_ok "Node.js $(node --version) | npm $(npm --version)"

# =============================================================================
# 5. CLAUDE CODE
# =============================================================================
log_section "Step 4b — Claude Code"

CLAUDE_PKG="@anthropic-ai/claude-code"

# Helper: get the installed global npm version of a package (empty if not installed)
npm_global_version() {
  npm list -g --depth=0 "$1" 2>/dev/null \
    | grep "$1" \
    | sed 's/.*@//' \
    | tr -d ' ' \
    || true
}

# ── Stale symlink / orphaned binary cleanup ───────────────────────────────────
# When Homebrew previously managed a 'claude' formula (or a cask placed a
# binary in the Homebrew prefix), it leaves a file at the Homebrew bin path
# that npm refuses to overwrite (EEXIST).  We detect and remove it before
# attempting any npm install/update.
BREW_PREFIX="$(brew --prefix)"
CLAUDE_BIN="${BREW_PREFIX}/bin/claude"

if [[ -e "$CLAUDE_BIN" || -L "$CLAUDE_BIN" ]]; then
  # Determine whether this is an npm-managed symlink or a Homebrew artifact
  if [[ -L "$CLAUDE_BIN" ]]; then
    LINK_TARGET="$(readlink "$CLAUDE_BIN")"
    if echo "$LINK_TARGET" | grep -q "node_modules"; then
      log_ok "Existing claude symlink points to npm — no cleanup needed."
    else
      log_warn "Stale non-npm symlink found at ${CLAUDE_BIN}"
      log_warn "  → points to: ${LINK_TARGET}"
      log_info "Removing stale symlink so npm can install cleanly…"
      rm -f "$CLAUDE_BIN"
      log_ok "Stale symlink removed."
    fi
  else
    # Regular file (e.g. a Homebrew-installed native binary)
    log_warn "Homebrew-managed 'claude' binary found at ${CLAUDE_BIN}."
    log_info "Unlinking via Homebrew (preferred) or removing directly…"
    if brew list claude &>/dev/null 2>&1; then
      brew unlink claude && log_ok "Unlinked Homebrew 'claude' formula."
    else
      rm -f "$CLAUDE_BIN"
      log_ok "Removed orphaned binary at ${CLAUDE_BIN}."
    fi
  fi
fi

# ── Install / update ──────────────────────────────────────────────────────────
INSTALLED_VERSION="$(npm_global_version "$CLAUDE_PKG")"
LATEST_VERSION="$(npm view "$CLAUDE_PKG" version 2>/dev/null || true)"

if [[ -z "$INSTALLED_VERSION" ]]; then
  log_info "Claude Code not found in npm globals. Installing ${CLAUDE_PKG}@latest…"
  # NOTE: Do NOT use sudo here — it causes permission issues with npm global installs
  npm install -g "$CLAUDE_PKG"
  log_ok "Claude Code installed: $(claude --version 2>/dev/null || echo 'run "claude --version" after opening a new shell')"
else
  log_ok "Claude Code already installed (v${INSTALLED_VERSION})."
  if [[ -n "$LATEST_VERSION" && "$INSTALLED_VERSION" != "$LATEST_VERSION" ]]; then
    log_info "Update available: v${INSTALLED_VERSION} → v${LATEST_VERSION}. Updating…"
    npm install -g "$CLAUDE_PKG"
    log_ok "Claude Code updated to v${LATEST_VERSION}."
  else
    log_ok "Claude Code is already at the latest version (v${INSTALLED_VERSION})."
  fi
fi

# =============================================================================
# SUMMARY
# =============================================================================
log_section "Installation Summary"
echo ""
printf "  %-20s %s\n" "Tool"          "Version"
printf "  %-20s %s\n" "────────────" "───────────────────"
printf "  %-20s %s\n" "Homebrew"      "$(brew --version | head -1)"
printf "  %-20s %s\n" "Azure CLI"     "$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'n/a')"
printf "  %-20s %s\n" "ripgrep"       "$(rg --version | head -1)"
printf "  %-20s %s\n" "Node.js"       "$(node --version)"
printf "  %-20s %s\n" "npm"           "$(npm --version)"
printf "  %-20s %s\n" "Claude Code"   "$(claude --version 2>/dev/null || echo 'open a new shell, then run: claude --version')"
echo ""
log_ok "All tools are installed and up to date."
echo ""
log_info "NEXT STEP: If 'claude' is not found, open a new terminal and run:"
echo -e "           ${CYAN}claude${RESET}"
echo ""