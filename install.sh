#!/usr/bin/env bash
set -euo pipefail

# NOTE: For native Windows (PowerShell), use install.ps1 instead.
# This script works on macOS, Linux, and Windows (via WSL/Git Bash/MSYS2).

# OpenCode Installer
# Installs opencode and deploys opencode.json + oh-my-opencode-slim.json
# to the global config directory for the current OS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILES=("opencode.json" "oh-my-opencode-slim.json")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}▸ %s${NC}\n" "$*"; }
ok()    { printf "${GREEN}✔ %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err()   { printf "${RED}✘ %s${NC}\n" "$*" >&2; exit 1; }

detect_os() {
  case "$(uname -s)" in
    Darwin*)  echo "macos" ;;
    Linux*)   echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)        err "Unsupported OS: $(uname -s)" ;;
  esac
}

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

MODIFIED_RC_FILES=()

append_to_rc() {
  local rc_file="$1"
  local line="$2"
  local match="${3:-$2}"

  if [[ ! -f "$rc_file" ]]; then
    return 0
  fi

  if grep -Fq -- "$match" "$rc_file"; then
    return 0
  fi

  printf '%s\n' "$line" >> "$rc_file"
  MODIFIED_RC_FILES+=("$rc_file")
}

ensure_on_path() {
  local dir="$1"
  if [[ -z "$dir" ]]; then
    return 0
  fi

  case ":${PATH:-}:" in
    *":${dir}:"*) ;;
    *) export PATH="${dir}:${PATH:-}" ;;
  esac

  local display_dir="$dir"
  local export_line="export PATH=\"${dir}:\$PATH\""
  if [[ "$dir" == "$HOME"/* ]]; then
    display_dir="\$HOME${dir#$HOME}"
    export_line="export PATH=\"${display_dir}:\$PATH\""
  fi
  if [[ "$dir" == "$HOME" ]]; then
    display_dir="\$HOME"
    export_line="export PATH=\"\$HOME:\$PATH\""
  fi

  local rc_match="$export_line"
  append_to_rc "$HOME/.zshrc" "$export_line" "$rc_match"
  append_to_rc "$HOME/.bashrc" "$export_line" "$rc_match"
  append_to_rc "$HOME/.bash_profile" "$export_line" "$rc_match"
  append_to_rc "$HOME/.profile" "$export_line" "$rc_match"

  local fish_config="$HOME/.config/fish/config.fish"
  local fish_line="fish_add_path -m ${display_dir}  # added by opencode installer"
  append_to_rc "$fish_config" "$fish_line" "$fish_line"

  # Fallback: if none of the rc files existed (nothing to append to and
  # entry not already present), create the most appropriate one so new
  # shells still pick up PATH.
  local _rc_found=0
  local _rc
  for _rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$fish_config"; do
    if [[ -f "$_rc" ]] && grep -Fq -- "$rc_match" "$_rc" 2>/dev/null; then
      _rc_found=1
      break
    fi
    if [[ -f "$_rc" ]] && grep -Fq -- "$fish_line" "$_rc" 2>/dev/null; then
      _rc_found=1
      break
    fi
  done
  if [[ $_rc_found -eq 0 ]]; then
    local fallback="$HOME/.profile"
    local fallback_line="$export_line"
    case "${SHELL:-}" in
      *fish*)
        fallback="$fish_config"
        fallback_line="$fish_line"
        ;;
      *bash*) fallback="$HOME/.bashrc" ;;
      *zsh*)  fallback="$HOME/.zshrc" ;;
    esac
    mkdir -p "$(dirname "$fallback")"
    if ! grep -Fq -- "$fallback_line" "$fallback" 2>/dev/null; then
      printf '%s\n' "$fallback_line" >> "$fallback"
      MODIFIED_RC_FILES+=("$fallback")
    fi
  fi
}

suggest_extra_path() {
  local method="$1"

  if [[ "$method" == "npm" ]]; then
    if command -v npm &>/dev/null; then
      local npm_bin=""
      npm_bin="$(npm bin -g 2>/dev/null || true)"
      if [[ -z "$npm_bin" ]]; then
        local npm_prefix=""
        npm_prefix="$(npm prefix -g 2>/dev/null || true)"
        if [[ -n "$npm_prefix" ]]; then
          npm_bin="${npm_prefix}/bin"
        fi
      fi
      if [[ -n "$npm_bin" ]]; then
        warn "npm global bin appears to be: ${npm_bin}"
        warn "If opencode lives there, add it to PATH in ~/.zshrc and ~/.bashrc, then restart your terminal."
      fi
    fi
  fi
  if [[ "$method" == "brew" ]]; then
    warn "Homebrew typically installs to /opt/homebrew/bin or /usr/local/bin."
    warn "Make sure that directory is on your PATH, then restart your terminal."
  fi
}

print_path_next_steps() {
  if [[ ${#MODIFIED_RC_FILES[@]} -eq 0 ]]; then
    return 0
  fi
  info "Added the opencode bin directory to PATH in:"
  local f printed=""
  for f in "${MODIFIED_RC_FILES[@]}"; do
    case "${printed}" in
      *"|${f}|"*) continue ;;
    esac
    printed="${printed}|${f}|"
    echo "  - ${f}"
  done
  echo ""
  warn "To use 'opencode' in this terminal right away, restart your terminal or run:"
  local _match="" _f
  case "${SHELL:-}" in
    *fish*)
      for _f in "${MODIFIED_RC_FILES[@]}"; do
        case "$_f" in *config.fish) _match="$_f"; break ;; esac
      done
      if [[ -n "$_match" ]]; then echo "    source ${_match}"; else echo "    source ~/.config/fish/config.fish"; fi
      ;;
    *bash*)
      for _f in "${MODIFIED_RC_FILES[@]}"; do
        case "$_f" in *".bash_profile"|*".profile") _match="$_f"; break ;; esac
      done
      if [[ -z "$_match" ]]; then
        for _f in "${MODIFIED_RC_FILES[@]}"; do
          case "$_f" in *".bashrc") _match="$_f"; break ;; esac
        done
      fi
      if [[ -n "$_match" ]]; then echo "    source ${_match}"; else echo "    source ~/.bashrc"; fi
      ;;
    *)
      for _f in "${MODIFIED_RC_FILES[@]}"; do
        case "$_f" in *".zshrc") _match="$_f"; break ;; esac
      done
      if [[ -z "$_match" && ${#MODIFIED_RC_FILES[@]} -gt 0 ]]; then
        _match="${MODIFIED_RC_FILES[0]}"
      fi
      if [[ -n "$_match" ]]; then echo "    source ${_match}"; else echo "    source ~/.zshrc"; fi
      ;;
  esac
  echo ""
}

detect_install_method() {
  local os="$1"

  if command -v curl &>/dev/null; then
    echo "curl"
    return
  fi

  if command -v npm &>/dev/null; then
    echo "npm"
    return
  fi

  if [[ "$os" == "macos" ]] && command -v brew &>/dev/null; then
    echo "brew"
    return
  fi

  err "No supported install method found. Please install curl, npm, or Homebrew first."
}

install_opencode() {
  local method="$1"

  if command -v opencode &>/dev/null; then
    local current_version
    current_version="$(opencode --version 2>/dev/null || echo "unknown")"
    warn "opencode is already installed (version: ${current_version}). Skipping install."
    if [[ -d "$HOME/.opencode/bin" ]]; then
      ensure_on_path "$HOME/.opencode/bin"
    fi
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

  if [[ -d "$HOME/.opencode/bin" ]]; then
    ensure_on_path "$HOME/.opencode/bin"
  fi

  if command -v npm &>/dev/null; then
    local npm_bin=""
    npm_bin="$(npm bin -g 2>/dev/null || true)"
    if [[ -z "$npm_bin" ]]; then
      local npm_prefix=""
      npm_prefix="$(npm prefix -g 2>/dev/null || true)"
      if [[ -n "$npm_prefix" ]]; then
        npm_bin="${npm_prefix}/bin"
      fi
    fi
    if [[ -n "$npm_bin" && "$npm_bin" != "$HOME/.opencode/bin" && -d "$npm_bin" ]]; then
      ensure_on_path "$npm_bin"
    fi
  fi

  if command -v opencode &>/dev/null; then
    ok "opencode installed: $(opencode --version 2>/dev/null || echo 'installed')"
  else
    suggest_extra_path "$method"
    err "opencode installation failed or is not on PATH. If your rc files were just updated, restart your terminal (or run 'source ~/.zshrc') and try again."
  fi
}

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
      local backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
      cp "$dst" "$backup"
      warn "Existing ${file} backed up → ${backup}"
    fi

    cp "$src" "$dst"
    ok "Deployed ${file} → ${dst}"
  done
}

main() {
  MODIFIED_RC_FILES=()
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

  install_opencode "$method"

  local cfg_dir
  cfg_dir="$(config_dir "$os")"
  deploy_configs "$cfg_dir"

  echo ""
  ok "All done! Run 'opencode' to get started."
  echo ""

  print_path_next_steps

  local answer=""
  read -r -p "Star the repo on GitHub if you find it useful? [y/N] " answer || true
  case "${answer:-}" in
    [yY]|[yY][eE][sS])
      if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        if gh api -X PUT "user/starred/HossamYoussof/opencode-config" --silent; then
          ok "Starred the repo."
        else
          warn "Couldn't star automatically — open the repo and star it manually."
        fi
      else
        warn "gh CLI not found or not signed in — open the repo and star it manually."
      fi
      case "$os" in
        macos)  open "https://github.com/HossamYoussof/opencode-config" ;;
        linux)  xdg-open "https://github.com/HossamYoussof/opencode-config" 2>/dev/null || true ;;
        windows) cmd.exe /c start "" "https://github.com/HossamYoussof/opencode-config" 2>/dev/null || true ;;
      esac
      ;;
  esac
  echo ""
}

main "$@"
