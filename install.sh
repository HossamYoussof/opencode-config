#!/usr/bin/env bash
set -euo pipefail

# NOTE: For native Windows (PowerShell), use install.ps1 instead.
# This script works on macOS, Linux, and Windows (via WSL/Git Bash/MSYS2).

# ──────────────────────────────────────────────────────────────────────
# OpenCode Installer
# Installs opencode and deploys opencode.json + oh-my-opencode-slim.json
# to the global config directory for the current OS.
# ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILES=("opencode.json" "oh-my-opencode-slim.json")

# ── Colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}▸ %s${NC}\n" "$*"; }
ok()    { printf "${GREEN}✔ %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err()   { printf "${RED}✘ %s${NC}\n" "$*" >&2; exit 1; }

# ── Detect OS ────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Darwin*)  echo "macos" ;;
    Linux*)   echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)        err "Unsupported OS: $(uname -s)" ;;
  esac
}

# ── Determine global config directory ────────────────────────────────
config_dir() {
  local os="$1"
  case "$os" in
    macos|linux)
      echo "${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
      ;;
    windows)
      if [[ -n "${APPDATA:-}" ]]; then
        echo "${APPDATA}/opencode"
      else
        echo "${USERPROFILE:-$HOME}/.config/opencode"
      fi
      ;;
  esac
}

# ── Detect best install method ───────────────────────────────────────
detect_install_method() {
  local os="$1"

  # Prefer the official curl script — works everywhere (incl. WSL)
  if command -v curl &>/dev/null; then
    echo "curl"
    return
  fi

  # npm fallback
  if command -v npm &>/dev/null; then
    echo "npm"
    return
  fi

  # Homebrew on macOS
  if [[ "$os" == "macos" ]] && command -v brew &>/dev/null; then
    echo "brew"
    return
  fi

  err "No supported install method found. Please install curl, npm, or Homebrew first."
}

# ── Install opencode ─────────────────────────────────────────────────
install_opencode() {
  local method="$1"

  if command -v opencode &>/dev/null; then
    local current_version
    current_version="$(opencode --version 2>/dev/null || echo "unknown")"
    warn "opencode is already installed (version: ${current_version}). Skipping install."
    return
  fi

  info "Installing opencode via ${method}..."

  case "$method" in
    curl)
      curl -fsSL https://opencode.ai/install | bash
      ;;
    npm)
      npm install -g opencode-ai
      ;;
    brew)
      brew install anomalyco/tap/opencode
      ;;
  esac

  # Verify
  if ! command -v opencode &>/dev/null; then
    # The curl installer may place it in ~/.opencode/bin — add to PATH for this session
    export PATH="$HOME/.opencode/bin:$PATH"
  fi

  if command -v opencode &>/dev/null; then
    ok "opencode installed: $(opencode --version 2>/dev/null || echo 'installed')"
  else
    err "opencode installation failed. Check the output above."
  fi
}

# ── Deploy config files ──────────────────────────────────────────────
deploy_configs() {
  local target_dir="$1"

  info "Config directory: ${target_dir}"
  mkdir -p "$target_dir"

  for file in "${CONFIG_FILES[@]}"; do
    local src="${SCRIPT_DIR}/${file}"
    local dst="${target_dir}/${file}"

    if [[ ! -f "$src" ]]; then
      err "Source file not found: ${src}"
    fi

    if [[ -f "$dst" ]]; then
      # Back up existing file
      local backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
      cp "$dst" "$backup"
      warn "Existing ${file} backed up → ${backup}"
    fi

    cp "$src" "$dst"
    ok "Deployed ${file} → ${dst}"
  done
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  echo ""
  printf "${CYAN}╔══════════════════════════════════════╗${NC}\n"
  printf "${CYAN}║       OpenCode Installer Script      ║${NC}\n"
  printf "${CYAN}╚══════════════════════════════════════╝${NC}\n"
  echo ""

  local os
  os="$(detect_os)"
  info "Detected OS: ${os}"

  local method
  method="$(detect_install_method "$os")"
  info "Install method: ${method}"

  # Step 1 — Install opencode
  install_opencode "$method"

  # Step 2 — Deploy config files
  local cfg_dir
  cfg_dir="$(config_dir "$os")"
  deploy_configs "$cfg_dir"

  echo ""
  ok "All done! Run 'opencode' to get started."
  echo ""
}

main "$@"
