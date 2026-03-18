#!/usr/bin/env bash
# =============================================================================
# setup_dev_tools.sh
# Installs/updates: Azure CLI, ripgrep, Claude Code
#
# Jamf Pro compatible — runs as root, executes tool commands as console user.
# Prerequisites: Homebrew and Node.js (v18+) already deployed to the machine.
#
# Created by:   Patrick Howell — IT/Systems Engineering
# Created:      2026-03-17
# Last updated: 2026-03-17 v1.8
# Log:          /var/log/setup_dev_tools.log
# =============================================================================

set -euo pipefail

LOG_FILE="/var/log/setup_dev_tools.log"

log()   { echo "$(date '+%F %T')  $*" | tee -a "$LOG_FILE"; }
ok()    { log "[OK]    $*"; }
info()  { log "[INFO]  $*"; }
warn()  { log "[WARN]  $*"; }
error() { log "[ERROR] $*" >&2; }

# =============================================================================
# Resolve the console user
# Jamf runs scripts as root. We use `su - <user>` to run brew/npm commands
# as the logged-in user. Root can su to any user without a password —
# no sudo rights required from the target user.
# =============================================================================
CONSOLE_USER="$(stat -f '%Su' /dev/console)"

if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
  error "No standard user logged in at the console. Exiting."
  exit 1
fi

info "Console user: ${CONSOLE_USER}"
touch "$LOG_FILE"
chmod 666 "$LOG_FILE"

# Convenience wrapper — runs a command as the console user via su.
# su from root requires no password and grants no elevated privileges.
as_user() {
  su - "$CONSOLE_USER" -c "$*"
}

# =============================================================================
# Verify prerequisites
# =============================================================================
if ! as_user "command -v brew" &>/dev/null; then
  error "Homebrew not found for user ${CONSOLE_USER}. Deploy Homebrew first."
  exit 1
fi

if ! as_user "command -v npm" &>/dev/null; then
  error "npm not found for user ${CONSOLE_USER}. Deploy Node.js (v18+) first."
  exit 1
fi

# =============================================================================
# 1. AZURE CLI
# =============================================================================
info "--- Azure CLI ---"

if as_user "brew list azure-cli" &>/dev/null 2>&1; then
  as_user "brew upgrade azure-cli" && ok "azure-cli upgraded." || warn "azure-cli already at latest version."
else
  info "Installing azure-cli…"
  as_user "brew install azure-cli"
  ok "azure-cli installed."
fi

# =============================================================================
# 2. RIPGREP
# =============================================================================
info "--- ripgrep ---"

if as_user "brew list ripgrep" &>/dev/null 2>&1; then
  as_user "brew upgrade ripgrep" && ok "ripgrep upgraded." || warn "ripgrep already at latest version."
else
  info "Installing ripgrep…"
  as_user "brew install ripgrep"
  ok "ripgrep installed."
fi

# =============================================================================
# 3. CLAUDE CODE
# =============================================================================
info "--- Claude Code ---"

CLAUDE_PKG="@anthropic-ai/claude-code"
BREW_PREFIX="$(as_user 'brew --prefix')"
CLAUDE_BIN="${BREW_PREFIX}/bin/claude"

# Remove any stale non-npm binary/symlink at the Homebrew bin path that would
# cause npm to error with EEXIST on install.
if [[ -L "$CLAUDE_BIN" ]]; then
  LINK_TARGET="$(readlink "$CLAUDE_BIN")"
  if ! echo "$LINK_TARGET" | grep -q "node_modules"; then
    warn "Stale symlink at ${CLAUDE_BIN} — removing."
    rm -f "$CLAUDE_BIN"
  fi
elif [[ -e "$CLAUDE_BIN" ]]; then
  warn "Non-npm file at ${CLAUDE_BIN} — removing."
  rm -f "$CLAUDE_BIN"
fi

INSTALLED="$(as_user "npm list -g --depth=0 ${CLAUDE_PKG} 2>/dev/null \
  | grep ${CLAUDE_PKG} | sed 's/.*@//' | tr -d ' '" || true)"
LATEST="$(as_user "npm view ${CLAUDE_PKG} version 2>/dev/null" || true)"

if [[ -z "$INSTALLED" ]]; then
  info "Installing Claude Code…"
  as_user "npm install -g ${CLAUDE_PKG}"
  ok "Claude Code installed."
elif [[ -n "$LATEST" && "$INSTALLED" != "$LATEST" ]]; then
  info "Updating Claude Code ${INSTALLED} → ${LATEST}…"
  as_user "npm install -g ${CLAUDE_PKG}"
  ok "Claude Code updated to ${LATEST}."
else
  ok "Claude Code ${INSTALLED} is already up to date."
fi

# =============================================================================
# SUMMARY
# =============================================================================
info "--- Summary ---"
ok "Azure CLI   $(as_user 'az version --query "azure-cli" -o tsv' 2>/dev/null || echo 'n/a')"
ok "ripgrep     $(as_user 'rg --version' | head -1)"
ok "Claude Code $(as_user 'claude --version' 2>/dev/null || echo 'verify in a new terminal')"
ok "All done."