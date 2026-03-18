#!/usr/bin/env bash
# =============================================================================
# install_dev_tools.sh
# Installs or updates: azure-cli, ripgrep, and Claude Code on macOS
#
# Supports:
#   - Run directly by the user (recommended for manual installs)
#   - Jamf Pro deployment (runs as root; detects the logged-in user)
#
# Requirements:
#   - macOS 12 Monterey or later
#   - Homebrew must already be installed for the target user
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
log()     { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()    { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
error()   { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }
section() {
  echo
  echo "========================================================"
  echo "  $*"
  echo "========================================================"
}

# ---------------------------------------------------------------------------
# Detect the real user and their home directory.
# Works whether the script is run directly by the user or via Jamf (as root).
# ---------------------------------------------------------------------------
detect_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    # Running as root (Jamf). Jamf passes the logged-in user as $3.
    REAL_USER="${3:-}"

    if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
      REAL_USER=$(stat -f '%Su' /dev/console 2>/dev/null || true)
    fi

    if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
      REAL_USER=$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null \
        | awk '/Name :/ && !/loginwindow/ { print $3 }' | head -1 || true)
    fi

    if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
      error "Could not detect a logged-in non-root user. Ensure a user is logged in."
    fi
  else
    # Running directly as the user.
    REAL_USER="$(id -un)"
  fi

  REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null \
    | awk '{print $2}')

  if [[ -z "$REAL_HOME" ]]; then
    REAL_HOME="/Users/$REAL_USER"
  fi

  log "Target user : $REAL_USER"
  log "Target home : $REAL_HOME"
}

# ---------------------------------------------------------------------------
# Run a command as REAL_USER.
# If already running as that user, execute directly (no sudo needed).
# If running as root (Jamf), use launchctl asuser so the full user session
# environment -- including PATH, Homebrew, etc. -- is available.
# ---------------------------------------------------------------------------
run_as_user() {
  local cmd="$*"
  if [[ "$(id -u)" -eq 0 ]]; then
    local uid
    uid=$(id -u "$REAL_USER")
    launchctl asuser "$uid" sudo -u "$REAL_USER" bash -l -c "$cmd"
  else
    bash -l -c "$cmd"
  fi
}

# ---------------------------------------------------------------------------
# Ensure Homebrew is installed and set BREW_BIN / BREW_PREFIX
# ---------------------------------------------------------------------------
ensure_homebrew() {
  section "Checking Homebrew"

  # Resolve brew binary: prefer login-shell PATH, then well-known locations.
  BREW_BIN=""

  BREW_BIN=$(run_as_user 'which brew 2>/dev/null' | tr -d '[:space:]' || true)

  if [[ -z "$BREW_BIN" || ! -x "$BREW_BIN" ]]; then
    if   [[ -x "/opt/homebrew/bin/brew" ]]; then
      BREW_BIN="/opt/homebrew/bin/brew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
      BREW_BIN="/usr/local/bin/brew"
    else
      error "Homebrew not installed. Install Homebrew first, then re-run this script."
    fi
  fi

  BREW_PREFIX=$("$BREW_BIN" --prefix)

  log "Homebrew   : $BREW_BIN"
  log "Prefix     : $BREW_PREFIX"

  # Ensure brew shellenv is wired into the user's .zprofile so installed
  # formula binaries are on PATH in every new terminal session.
  local zprofile="$REAL_HOME/.zprofile"
  local shellenv_line='eval "$(/opt/homebrew/bin/brew shellenv)"'

  # Adjust for Intel Macs
  if [[ "$BREW_PREFIX" == "/usr/local" ]]; then
    shellenv_line='eval "$(/usr/local/bin/brew shellenv)"'
  fi

  if ! grep -qF 'brew shellenv' "$zprofile" 2>/dev/null; then
    log "Adding Homebrew shellenv to $zprofile"
    echo "" >> "$zprofile"
    echo "# Homebrew" >> "$zprofile"
    echo "$shellenv_line" >> "$zprofile"
    chown "$REAL_USER" "$zprofile"
  else
    log "Homebrew shellenv already in $zprofile"
  fi
}

# ---------------------------------------------------------------------------
# Install or upgrade a Homebrew formula
# ---------------------------------------------------------------------------
brew_install_or_upgrade() {
  local formula="$1"
  log "Processing: $formula"

  if run_as_user "$BREW_BIN list --formula 2>/dev/null | grep -qx '$formula'"; then
    log "$formula already installed -- upgrading if needed..."
    run_as_user "$BREW_BIN upgrade $formula" \
      && log "$formula upgraded." \
      || log "$formula already at latest version."
  else
    log "$formula not found -- installing..."
    run_as_user "$BREW_BIN install $formula"
    log "$formula installed."
  fi
}

# ---------------------------------------------------------------------------
# Install or upgrade Claude Code (native binary)
# After install, symlink into /usr/local/bin so it is always on PATH
# regardless of shell profile state.
# ---------------------------------------------------------------------------
install_or_upgrade_claude_code() {
  section "Claude Code"

  local claude_bin="$REAL_HOME/.claude/bin/claude"

  if [[ -x "$claude_bin" ]]; then
    log "Claude Code found at $claude_bin -- updating..."
    run_as_user 'claude update' \
      && log "Claude Code updated (or already current)." \
      || {
          warn "'claude update' failed -- re-running native installer."
          run_as_user 'curl -fsSL https://claude.ai/install.sh | bash'
        }
  else
    log "Claude Code not found -- installing via native installer..."
    run_as_user 'curl -fsSL https://claude.ai/install.sh | bash'
    log "Claude Code installed."
  fi

  # Symlink claude into /usr/local/bin so it is on PATH immediately in all
  # terminal sessions without needing to reload the shell profile.
  if [[ -x "$claude_bin" ]]; then
    ln -sf "$claude_bin" /usr/local/bin/claude
    log "Symlinked $claude_bin -> /usr/local/bin/claude"
  else
    warn "Could not find claude binary at $claude_bin after install."
  fi

  # Also ensure ~/.claude/bin is in the user's .zprofile for completeness.
  local zprofile="$REAL_HOME/.zprofile"
  if ! grep -qF '.claude/bin' "$zprofile" 2>/dev/null; then
    log "Adding ~/.claude/bin to PATH in $zprofile"
    echo "" >> "$zprofile"
    echo "# Claude Code" >> "$zprofile"
    echo 'export PATH="$HOME/.claude/bin:$PATH"' >> "$zprofile"
    chown "$REAL_USER" "$zprofile"
  else
    log "Claude Code PATH already in $zprofile"
  fi

  local version
  version=$(/usr/local/bin/claude --version 2>/dev/null | head -1 || echo "unknown")
  log "Claude Code version: $version"
}

# ---------------------------------------------------------------------------
# Verify all tools resolve to a binary and print versions for the audit log
# ---------------------------------------------------------------------------
verify_tools() {
  section "Verification"
  local all_ok=true

  # Verify using absolute known paths to avoid PATH ambiguity at this stage.
  declare -A TOOL_PATHS=(
    ["az"]="$BREW_PREFIX/bin/az"
    ["rg"]="$BREW_PREFIX/bin/rg"
    ["claude"]="/usr/local/bin/claude"
  )

  for tool in az rg claude; do
    local path="${TOOL_PATHS[$tool]}"
    if [[ -x "$path" ]]; then
      local version
      version=$("$path" --version 2>/dev/null | head -1)
      log "  [OK]   $tool -> $path ($version)"
    else
      warn "  [FAIL] $tool not found at $path"
      all_ok=false
    fi
  done

  if [[ "$all_ok" != true ]]; then
    error "One or more tools failed verification. See warnings above."
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  section "macOS Developer Tools Installer"
  log "Script version : 1.2.0"
  log "macOS version  : $(sw_vers -productVersion)"
  log "Architecture   : $(uname -m)"

  # Must be root (Jamf) or the actual target user
  if [[ "$(id -u)" -ne 0 && "$(id -un)" == "root" ]]; then
    error "Run this script as your user or as root (via Jamf)."
  fi

  detect_user

  # 1. Homebrew
  ensure_homebrew

  # 2. Azure CLI
  section "Azure CLI"
  brew_install_or_upgrade "azure-cli"

  # 3. ripgrep
  section "ripgrep"
  brew_install_or_upgrade "ripgrep"

  # 4. Claude Code
  install_or_upgrade_claude_code

  # 5. Verification
  verify_tools

  section "Complete"
  log "All tools installed and verified."
  log "Open a new terminal window (or run: source ~/.zprofile) to use them."
  exit 0
}

main "$@"