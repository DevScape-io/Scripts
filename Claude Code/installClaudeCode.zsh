#!/usr/bin/env bash
# =============================================================================
# install_dev_tools.sh
# Installs or updates: azure-cli, ripgrep, and Claude Code on macOS
#
# Supports:
#   - Interactive use (run manually by a developer)
#   - Jamf Pro deployment (run as a Policy script; see accompanying docs)
#
# Requirements:
#   - macOS 12 Monterey or later
#   - Homebrew installed (script auto-installs it if missing)
#   - Internet access
#
# Usage:
#   chmod +x install_dev_tools.sh
#   ./install_dev_tools.sh
#
# Exit codes:
#   0  - Success
#   1  - Fatal error (see log output)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()    { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()   { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
error()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }
section(){ echo; echo "========================================================"; echo "  $*"; echo "========================================================"; }

# ---------------------------------------------------------------------------
# Detect the real user when running under Jamf (which runs as root)
# ---------------------------------------------------------------------------
detect_user() {
  # Jamf sets the logged-in user as $3; fall back to console session query
  REAL_USER="${3:-$(stat -f '%Su' /dev/console 2>/dev/null || echo '')}"

  if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER=$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null \
      | awk '/Name :/ && !/loginwindow/ { print $3 }' | head -1)
  fi

  if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    error "Could not detect a logged-in non-root user. Ensure a user is logged in before running this policy."
  fi

  REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null \
    | awk '{print $2}')

  log "Detected user  : $REAL_USER"
  log "Detected home  : $REAL_HOME"
}

# ---------------------------------------------------------------------------
# Run a command as the real (non-root) user
# ---------------------------------------------------------------------------
run_as_user() {
  sudo -H -u "$REAL_USER" bash -c "$*"
}

# ---------------------------------------------------------------------------
# Ensure Homebrew is installed
# ---------------------------------------------------------------------------
ensure_homebrew() {
  section "Checking Homebrew"

  if ! run_as_user 'command -v brew &>/dev/null'; then
    error "Homebrew not installed. Install Homebrew first, then re-run this script."
  fi

  log "Homebrew already installed."

  # Ensure brew is on PATH for subsequent steps (Apple Silicon aware)
  BREW_PREFIX=$(run_as_user 'brew --prefix 2>/dev/null || echo /usr/local')
  export PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"
  log "Homebrew prefix: $BREW_PREFIX"
}

# ---------------------------------------------------------------------------
# Install or upgrade a Homebrew formula
# ---------------------------------------------------------------------------
brew_install_or_upgrade() {
  local formula="$1"
  log "Processing Homebrew formula: $formula"

  if run_as_user "brew list --formula 2>/dev/null | grep -qx '${formula}'"; then
    log "$formula is already installed — checking for updates..."
    run_as_user "brew upgrade $formula 2>&1 | grep -v 'already installed'"  \
      && log "$formula is up to date." \
      || warn "brew upgrade $formula exited non-zero (may already be current)."
  else
    log "$formula not found — installing..."
    run_as_user "brew install $formula"
    log "$formula installed successfully."
  fi
}

# ---------------------------------------------------------------------------
# Install or upgrade Claude Code (native binary — preferred method)
# ---------------------------------------------------------------------------
install_or_upgrade_claude_code() {
  section "Claude Code"

  if run_as_user 'command -v claude &>/dev/null'; then
    log "Claude Code binary found — running self-update..."
    # 'claude update' exits 0 even when already current
    run_as_user 'claude update' \
      && log "Claude Code updated (or already current)." \
      || {
          warn "'claude update' failed — falling back to native installer."
          run_as_user 'curl -fsSL https://claude.ai/install.sh | bash'
          log "Claude Code re-installed via native installer."
        }
  else
    log "Claude Code not found — installing via native installer..."
    # The native installer requires no Node.js dependency and auto-updates
    run_as_user 'curl -fsSL https://claude.ai/install.sh | bash'
    log "Claude Code installed successfully."
  fi

  # Print installed version for audit log
  CLAUDE_VERSION=$(run_as_user 'claude --version 2>/dev/null || echo unknown')
  log "Claude Code version: $CLAUDE_VERSION"
}

# ---------------------------------------------------------------------------
# Verify all tools are present and emit versions for audit
# ---------------------------------------------------------------------------
verify_tools() {
  section "Verification"
  local all_ok=true

  for tool in az rg claude; do
    if run_as_user "command -v $tool &>/dev/null"; then
      VERSION=$(run_as_user "$tool --version 2>/dev/null | head -1")
      log "✓ $tool  →  $VERSION"
    else
      warn "✗ $tool not found on PATH after installation."
      all_ok=false
    fi
  done

  if [[ "$all_ok" != true ]]; then
    error "One or more tools failed to install. Review the output above."
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  section "macOS Developer Tools Installer"
  log "Script version : 1.0.0"
  log "macOS version  : $(sw_vers -productVersion)"
  log "Architecture   : $(uname -m)"

  detect_user

  # ── 1. Homebrew ──────────────────────────────────────────────────────────
  ensure_homebrew

  # ── 2. Azure CLI ─────────────────────────────────────────────────────────
  section "Azure CLI"
  brew_install_or_upgrade "azure-cli"

  # ── 3. ripgrep ───────────────────────────────────────────────────────────
  section "ripgrep"
  brew_install_or_upgrade "ripgrep"

  # ── 4. Claude Code ───────────────────────────────────────────────────────
  install_or_upgrade_claude_code

  # ── 5. Verification ──────────────────────────────────────────────────────
  verify_tools

  section "Complete"
  log "All tools installed and verified successfully."
  exit 0
}

main "$@"