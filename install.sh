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

# ---- installer options (set via flags; see usage in main) ----
NON_INTERACTIVE=0
SKIP_MCP=0
INSTALL_TYPE="${OPENCODE_INSTALL_TYPE:-}"

# Set to 1 when THIS run actually persists a new secret via
# customize_opencode_json (gates the auto service-restart in main so
# merely-inherited env vars can't trigger a restart on their own).
SECRETS_SAVED_THIS_RUN=0

# Cache for `npm bin -g` detection (avoids spawning node repeatedly).
_NPM_BIN_CACHE_SET=0
_NPM_BIN_CACHE=""

# Staging file for deploy_configs; cleaned explicitly at the end of
# deploy_configs (function form so paths with spaces are safe).
# No EXIT trap is installed so sourcing this file never affects the caller
# and repeated calls cannot orphan an earlier staging file.
_STAGING_FILE=""
_cleanup_staging() {
  if [[ -n "${_STAGING_FILE:-}" && -f "$_STAGING_FILE" ]]; then
    rm -f "$_STAGING_FILE"
  fi
  _STAGING_FILE=""
}

# Pick the most appropriate sh rc as a fallback when no rc file exists yet.
# Single source of truth (used by secret persist + ensure_on_path).
_fallback_sh_rc() {
  case "${SHELL:-}" in
    *bash*) printf '%s' "$HOME/.bashrc" ;;
    *zsh*)  printf '%s' "$HOME/.zshrc" ;;
    *)      printf '%s' "$HOME/.profile" ;;
  esac
}

# npm global bin, computed at most once per run. Sets _NPM_BIN_CACHE /
# _NPM_BIN_CACHE_SET globals — call WITHOUT command substitution so the
# cache persists (e.g. `_npm_global_bin; bin="$_NPM_BIN_CACHE"`).
_npm_global_bin() {
  if [[ "$_NPM_BIN_CACHE_SET" -eq 1 ]]; then
    return 0
  fi
  _NPM_BIN_CACHE_SET=1
  _NPM_BIN_CACHE=""
  local _bin="" _prefix=""
  _bin="$(npm bin -g 2>/dev/null || true)"
  if [[ -z "$_bin" ]]; then
    _prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$_prefix" ]]; then
      _bin="${_prefix}/bin"
    fi
  fi
  _NPM_BIN_CACHE="$_bin"
}

# Escape a secret value for safe embedding in double quotes in an rc file.
_escape_for_export() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\$/\\\$}"
  v="${v//\`/\\\`}"
  printf '%s' "$v"
}

# True (0) when the value is empty or whitespace-only.
_is_blank() {
  case "$1" in
    '') return 0 ;;
    *[![:space:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

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

# Batch variant: upsert up to two `export NAME=` lines in ONE awk pass per
# rc file, so saving both secrets costs one spawn per file instead of two.
_batch_upsert_exports_in_rc() {
  local rc_file="$1"
  local name1="$2" line1="$3" name2="${4:-}" line2="${5:-}"

  mkdir -p "$(dirname "$rc_file")"
  if [[ ! -f "$rc_file" ]]; then
    if printf '%s\n' "$line1" >> "$rc_file"; then
      if [[ -n "$name2" ]]; then
        if ! printf '%s\n' "$line2" >> "$rc_file"; then
          warn "Could not update secrets in ${rc_file} — update it manually if needed."
          return 1
        fi
      fi
      chmod 600 "$rc_file" || true
      return 0
    else
      warn "Could not update secrets in ${rc_file} — update it manually if needed."
      return 1
    fi
  fi

  local tmp
  tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/opencode-rc-$$.tmp")"
  # Same as above: lines via environment so awk won't eat backslashes.
  if __L1="$line1" __L2="$line2" awk -v n1="$name1" -v n2="$name2" '
    BEGIN { l1 = ENVIRON["__L1"]; l2 = ENVIRON["__L2"]; r1 = 0; r2 = 0 }
    {
      if ($0 ~ ("^[[:space:]]*export " n1 "=")) {
        if (!r1) { print l1; r1 = 1 }
        next
      }
      if (n2 != "" && ($0 ~ ("^[[:space:]]*export " n2 "="))) {
        if (!r2) { print l2; r2 = 1 }
        next
      }
      print
    }
    END {
      if (!r1) print l1
      if (n2 != "" && !r2) print l2
    }
  ' "$rc_file" > "$tmp" 2>/dev/null; then
    if cat "$tmp" > "$rc_file"; then
      rm -f "$tmp"
    else
      rm -f "$tmp"
      warn "Could not update secrets in ${rc_file} — update it manually if needed."
      return 1
    fi
  else
    rm -f "$tmp"
    warn "Could not update secrets in ${rc_file} — update it manually if needed."
    return 1
  fi
}

# Save one or two secrets to the shell rcs in a single pass per file.
# Messages intentionally mirror the old per-secret wording so re-runs
# still report each secret name.
persist_secrets_to_rc() {
  local name1="$1" value1="$2" name2="${3:-}" value2="${4:-}"
  local line1="export ${name1}=\"$(_escape_for_export "$value1")\""
  local line2=""
  if [[ -n "$name2" ]]; then
    line2="export ${name2}=\"$(_escape_for_export "$value2")\""
  fi

  local target_rcs=()
  local rc
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [[ -f "$rc" ]]; then
      target_rcs+=("$rc")
    fi
  done

  local _saved_any=0
  if [[ ${#target_rcs[@]} -eq 0 ]]; then
    local fallback
    fallback="$(_fallback_sh_rc)"
    mkdir -p "$(dirname "$fallback")"
    if _batch_upsert_exports_in_rc "$fallback" "$name1" "$line1" "$name2" "$line2"; then
      chmod 600 "$fallback" || true
      MODIFIED_RC_FILES+=("$fallback")
      ok "Saved ${name1} to ${fallback}."
      if [[ -n "$name2" ]]; then
        ok "Saved ${name2} to ${fallback}."
      fi
      if [[ -n "$name2" ]]; then
        warn "Run 'source ${fallback}' or restart your terminal to apply ${name1} and ${name2}."
      else
        warn "Run 'source ${fallback}' or restart your terminal to apply ${name1}."
      fi
      _saved_any=1
    fi
    # else: batch already warned; no success message.
  else
    for rc in "${target_rcs[@]}"; do
      if _batch_upsert_exports_in_rc "$rc" "$name1" "$line1" "$name2" "$line2"; then
        MODIFIED_RC_FILES+=("$rc")
        ok "Saved ${name1} to ${rc}."
        if [[ -n "$name2" ]]; then
          ok "Saved ${name2} to ${rc}."
        fi
        warn "${rc} may be world-readable — consider 'chmod 600 ${rc}' since it now holds a secret."
        _saved_any=1
      fi
      # else: batch already warned; no success message for this file.
    done
    if [[ $_saved_any -eq 1 ]]; then
      if [[ -n "$name2" ]]; then
        warn "Run 'source ~/.zshrc' / 'source ~/.bashrc' or restart your terminal to apply ${name1} and ${name2}."
      else
        warn "Run 'source ~/.zshrc' / 'source ~/.bashrc' or restart your terminal to apply ${name1}."
      fi
    fi
  fi
  if [[ $_saved_any -eq 1 ]]; then
    warn "After reloading your shell, restart the service so it picks up the new env: opencode service restart && opencode mcp list"
    return 0
  fi
  # Total failure: report nonzero so callers skip their Saved messages
  # and the saved-this-run flag (batch already warned per file).
  return 1
}

persist_secret_to_rc() {
  persist_secrets_to_rc "$1" "$2"
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

  local fish_config="$HOME/.config/fish/config.fish"
  local fish_line="fish_add_path -m ${display_dir}  # added by opencode installer"
  # Note whether any rc file existed BEFORE appending: append_to_rc only
  # touches existing files, so the fallback is needed solely when none
  # existed (no re-scan greps — the lines can't be present in files that
  # don't exist).
  local had_rc=0
  local _rc
  for _rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$fish_config"; do
    if [[ -f "$_rc" ]]; then
      had_rc=1
      break
    fi
  done

  append_to_rc "$HOME/.zshrc" "$export_line" "$rc_match"
  append_to_rc "$HOME/.bashrc" "$export_line" "$rc_match"
  append_to_rc "$HOME/.bash_profile" "$export_line" "$rc_match"
  append_to_rc "$HOME/.profile" "$export_line" "$rc_match"
  append_to_rc "$fish_config" "$fish_line" "$fish_line"

  # Fallback: none of the rc files existed, so nothing was appended above.
  # Create the most appropriate one so new shells still pick up PATH.
  if [[ $had_rc -eq 0 ]]; then
    local fallback fallback_line="$export_line"
    case "${SHELL:-}" in
      *fish*)
        fallback="$fish_config"
        fallback_line="$fish_line"
        ;;
      *)
        fallback="$(_fallback_sh_rc)"
        ;;
    esac
    mkdir -p "$(dirname "$fallback")"
    printf '%s\n' "$fallback_line" >> "$fallback"
    MODIFIED_RC_FILES+=("$fallback")
  fi
}

suggest_extra_path() {
  local method="$1"

  if [[ "$method" == "npm" ]]; then
    if command -v npm &>/dev/null; then
      _npm_global_bin
      if [[ -n "$_NPM_BIN_CACHE" ]]; then
        warn "npm global bin appears to be: ${_NPM_BIN_CACHE}"
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

# Compare two semantic versions (major.minor.patch).
# Returns 0 if v1 < v2, 1 if v1 >= v2, 2 if either is invalid.
version_lt() {
  local v1="$1" v2="$2"
  [[ "$v1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  [[ "$v2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  local IFS=.
  read -ra a1 <<< "$v1"
  read -ra a2 <<< "$v2"
  for i in 0 1 2; do
    if (( a1[i] < a2[i] )); then return 0; fi
    if (( a1[i] > a2[i] )); then return 1; fi
  done
  return 1
}

# Get the latest available version for the given install method.
# Echoes the version string (e.g., "1.2.3") on success, empty on failure.
get_latest_version() {
  local method="$1"
  case "$method" in
    npm)
      npm view @opencode/cli version 2>/dev/null
      ;;
    brew)
      brew info --json=v2 anomalyco/tap/opencode-v2 2>/dev/null | \
        python3 -c "import sys, json; data=json.load(sys.stdin); print(data['formulae'][0]['versions']['stable'])" 2>/dev/null
      ;;
    curl)
      # Fetch latest version from official opencode API (same as official installer)
      local api_response
      api_response="$(curl -fsSL "https://opencode.ai/update/api/latest/cli/npm" 2>/dev/null)" || return 1
      python3 -c "import sys, json; data=json.loads(sys.argv[1]); print(data['version'])" "$api_response" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

install_opencode() {
  local method="$1"

  local latest_version
  latest_version="$(get_latest_version "$method")" || latest_version=""

  local should_install=0

  if command -v opencode &>/dev/null; then
    local current_version_raw
    current_version_raw="$(opencode --version 2>/dev/null || echo "unknown")"
    # Strip "opencode v" prefix if present (e.g., "opencode v2.1.2" -> "2.1.2")
    local current_version="${current_version_raw#opencode v}"
    
    if [[ -n "$latest_version" && "$current_version" != "unknown" ]]; then
      local cmp
      if version_lt "$current_version" "$latest_version"; then
        cmp=0
      else
        cmp=$?
      fi
      if [[ $cmp -eq 0 ]]; then
        info "Update available: ${current_version} → ${latest_version}"
        if [[ "$NON_INTERACTIVE" -eq 1 || ! -t 0 ]]; then
          info "Non-interactive mode: proceeding with update."
          should_install=1
        else
          local answer=""
          read -r -p "Update to ${latest_version}? [Y/n] " answer || true
          case "${answer:-}" in
            [nN]|[nN][oO])
              info "Skipping update. Will deploy config files for current version."
              should_install=0
              ;;
            *)
              should_install=1
              ;;
          esac
        fi
      elif [[ $cmp -eq 1 ]]; then
        ok "opencode is up to date (version: ${current_version})."
        should_install=0
      else
        warn "Could not compare versions (current: ${current_version}, latest: ${latest_version})."
        should_install=0
      fi
    else
      warn "opencode is already installed (version: ${current_version})."
      should_install=0
    fi
  else
    info "opencode not found. Installing latest version (${latest_version:-unknown})..."
    should_install=1
  fi

  if [[ $should_install -eq 1 ]]; then
    info "Installing opencode via ${method}..."

    case "$method" in
      curl)
        curl -fsSL https://opencode.ai/v2/install | bash
        ;;
      npm)
        npm install -g @opencode/cli
        ;;
      brew)
        brew upgrade anomalyco/tap/opencode-v2 2>/dev/null || brew install anomalyco/tap/opencode-v2
        ;;
    esac

    if [[ -d "$HOME/.opencode/bin" ]]; then
      ensure_on_path "$HOME/.opencode/bin"
    fi

    if command -v npm &>/dev/null; then
      _npm_global_bin
      if [[ -n "$_NPM_BIN_CACHE" && "$_NPM_BIN_CACHE" != "$HOME/.opencode/bin" && -d "$_NPM_BIN_CACHE" ]]; then
        ensure_on_path "$_NPM_BIN_CACHE"
      fi
    fi

    if command -v opencode &>/dev/null; then
      ok "opencode installed: $(opencode --version 2>/dev/null || echo 'installed')"
    else
      suggest_extra_path "$method"
      err "opencode installation failed or is not on PATH. If your rc files were just updated, restart your terminal (or run 'source ~/.zshrc') and try again."
    fi
  else
    # Not installing/updating, but still ensure PATH is set
    if [[ -d "$HOME/.opencode/bin" ]]; then
      ensure_on_path "$HOME/.opencode/bin"
    fi
    if command -v npm &>/dev/null; then
      _npm_global_bin
      if [[ -n "$_NPM_BIN_CACHE" && "$_NPM_BIN_CACHE" != "$HOME/.opencode/bin" && -d "$_NPM_BIN_CACHE" ]]; then
        ensure_on_path "$_NPM_BIN_CACHE"
      fi
    fi
  fi

  return 0
}

# Resolve the desktop installer download URL and target filename for the current OS and architecture.
# Prints: <download_url> <filename>
get_desktop_download_url() {
  local os="$1"
  local arch
  arch="$(uname -m 2>/dev/null || echo "x86_64")"

  local target_file=""
  case "$os" in
    macos)
      case "$arch" in
        arm64|aarch64) target_file="opencode-desktop-mac-arm64.dmg" ;;
        *)             target_file="opencode-desktop-mac-x64.dmg" ;;
      esac
      ;;
    linux)
      case "$arch" in
        arm64|aarch64) target_file="opencode-desktop-linux-arm64.AppImage" ;;
        *)             target_file="opencode-desktop-linux-x86_64.AppImage" ;;
      esac
      ;;
    windows)
      case "$arch" in
        arm64|aarch64) target_file="opencode-desktop-win-arm64.exe" ;;
        *)             target_file="opencode-desktop-win-x64.exe" ;;
      esac
      ;;
    *)
      err "Unsupported OS for Desktop installation: $os"
      ;;
  esac

  local api_url="https://opencode.ai/update/api/latest/desktop"
  local download_url=""

  if command -v curl &>/dev/null && command -v python3 &>/dev/null; then
    local json_response
    json_response="$(curl -fsSL --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null || true)"
    if [[ -n "$json_response" ]]; then
      download_url="$(python3 -c "
import sys, json
target = sys.argv[1]
try:
    data = json.loads(sys.argv[2])
    files = data['artifacts'][0]['metadata']['files']
    if target in files:
        print(files[target]['url'])
except Exception:
    pass
" "$target_file" "$json_response" 2>/dev/null || true)"
    fi
  fi

  # Fallback to standard URL scheme if API lookup failed
  if [[ -z "$download_url" ]]; then
    local fallback_version="2.4.1"
    download_url="https://opencode.ai/files/bin/${fallback_version}/${target_file}"
  fi

  printf '%s %s\n' "$download_url" "$target_file"
}

# Locate an existing OpenCode Desktop installation for the current OS.
# Prints the path if found and returns 0; otherwise returns 1.
find_desktop_app() {
  local os="$1"
  case "$os" in
    macos)
      local app
      for app in "/Applications/OpenCode.app" "$HOME/Applications/OpenCode.app"; do
        if [[ -d "$app" ]]; then
          printf '%s\n' "$app"
          return 0
        fi
      done
      ;;
    linux)
      if command -v opencode-desktop &>/dev/null; then
        command -v opencode-desktop
        return 0
      fi
      local bin
      for bin in \
        "/usr/bin/opencode-desktop" \
        "/usr/local/bin/opencode-desktop" \
        "/opt/OpenCode/opencode-desktop" \
        "/opt/opencode-desktop/opencode-desktop" \
        "$HOME/.local/bin/opencode-desktop"; do
        if [[ -x "$bin" ]]; then
          printf '%s\n' "$bin"
          return 0
        fi
      done
      local dir match
      for dir in "$HOME/.local/bin" "$HOME/Applications" "$HOME/Downloads"; do
        [[ -d "$dir" ]] || continue
        for match in "$dir"/opencode-desktop*.AppImage "$dir"/OpenCode*.AppImage; do
          if [[ -e "$match" ]]; then
            printf '%s\n' "$match"
            return 0
          fi
        done
      done
      ;;
    windows)
      local exe
      local local_app="${LOCALAPPDATA:-}"
      local prog_files="${PROGRAMFILES:-${ProgramFiles:-}}"
      local prog_files_x86="${PROGRAMFILES_X86:-}"
      for exe in \
        "${local_app:+$local_app/Programs/OpenCode/OpenCode.exe}" \
        "${local_app:+$local_app/OpenCode/OpenCode.exe}" \
        "${prog_files:+$prog_files/OpenCode/OpenCode.exe}" \
        "${prog_files_x86:+$prog_files_x86/OpenCode/OpenCode.exe}"; do
        if [[ -n "$exe" && -f "$exe" ]]; then
          printf '%s\n' "$exe"
          return 0
        fi
      done
      ;;
  esac
  return 1
}

# Download and launch the Desktop installer
download_and_install_desktop() {
  local os="$1"

  local existing_app
  if existing_app="$(find_desktop_app "$os")"; then
    ok "OpenCode Desktop is already installed (${existing_app}). Skipping download."
    return 0
  fi

  info "Resolving OpenCode Desktop download..."

  local info_str
  info_str="$(get_desktop_download_url "$os")"
  local download_url filename
  download_url="$(echo "$info_str" | awk '{print $1}')"
  filename="$(echo "$info_str" | awk '{print $2}')"

  local download_dir="$HOME/Downloads"
  if [[ ! -d "$download_dir" || ! -w "$download_dir" ]]; then
    download_dir="${TMPDIR:-/tmp}"
  fi

  local target_path="${download_dir}/${filename}"

  info "Downloading OpenCode Desktop (${filename}) to ${download_dir}..."
  if command -v curl &>/dev/null; then
    if ! curl -fL --progress-bar "$download_url" -o "$target_path"; then
      err "Failed to download OpenCode Desktop from $download_url"
    fi
  elif command -v wget &>/dev/null; then
    if ! wget -q --show-progress "$download_url" -O "$target_path"; then
      err "Failed to download OpenCode Desktop from $download_url"
    fi
  else
    err "Neither curl nor wget found. Cannot download OpenCode Desktop."
  fi

  ok "Downloaded OpenCode Desktop → ${target_path}"

  case "$os" in
    macos)
      info "Opening installer image in Finder..."
      open "$target_path" || warn "Could not open ${target_path} automatically. Open it manually in Finder."
      ok "OpenCode Desktop installer opened. Drag OpenCode.app to Applications to complete setup."
      ;;
    linux)
      chmod +x "$target_path" || true
      info "OpenCode Desktop saved as executable AppImage: ${target_path}"
      info "You can run it with: '${target_path}' or move it to ~/.local/bin/"
      ;;
    windows)
      info "Launching installer..."
      cmd.exe /c start "" "$target_path" 2>/dev/null || warn "Could not launch ${target_path} automatically. Run it from File Explorer."
      ;;
  esac
}

customize_opencode_json() {
  local src_file="$1"
  local staging_file="$2"

  cp "$src_file" "$staging_file"

  # Secrets may come from the environment (non-interactive use): GITHUB_PAT.
  local github_pat="${GITHUB_PAT:-}"
  local prompted=0

  if [[ "$SKIP_MCP" -eq 1 ]]; then
    info "Skipping MCP credential prompts (--skip-mcp)."
    github_pat=""
    return 0
  elif [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    info "Non-interactive mode: using credential values from the environment (if set)."
  elif [[ ! -t 0 ]]; then
    info "No interactive input available — using credential values from the environment (if set)."
  else
    prompted=1
    local _pat=""
    # Only prompt for values not already provided via the environment.
    if [[ -z "$github_pat" ]]; then
      read -r -s -p "GitHub PAT for MCP (optional, Enter to skip): " _pat || true
      printf '\n'
      github_pat="$_pat"
    fi
    _pat=""
    unset _pat
  fi

  # Light validation: warn-and-skip bad values instead of storing them.
  if _is_blank "$github_pat"; then
    github_pat=""
  fi

  if [[ -z "${github_pat}" ]]; then
    if [[ "$prompted" -eq 0 ]]; then
      info "No MCP credentials in the environment — skipping (re-run interactively or set GITHUB_PAT to configure)."
    fi
    return 0
  fi

  # Persist raw secrets to shell rc + current session only. They are NEVER
  # written into the deployed opencode.json; the JSON keeps `Bearer {env:GITHUB_PAT}`.
  export GITHUB_PAT="${github_pat}"
  if persist_secret_to_rc "GITHUB_PAT" "${github_pat}"; then
    SECRETS_SAVED_THIS_RUN=1
    ok "Saved GITHUB_PAT to shell rc; config keeps {env:GITHUB_PAT}."
  fi

  # Reduce exposure of raw secrets in this shell.
  github_pat=""
  unset github_pat
}


deploy_configs() {
  local target_dir="$1"

  info "Config directory: ${target_dir}"
  mkdir -p "$target_dir"

  local staging=""
  staging="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/opencode-staging-$$.json")"
  _STAGING_FILE="$staging"

  for file in "${CONFIG_FILES[@]}"; do
    local src="${SCRIPT_DIR}/${file}"
    local dst="${target_dir}/${file}"

    if [[ ! -f "$src" ]]; then
      rm -f "$staging"
      _STAGING_FILE=""
      err "Source file not found: ${src}"
    fi

    if [[ -f "$dst" ]]; then
      local backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
      cp "$dst" "$backup"
      warn "Existing ${file} backed up → ${backup}"
    fi

    local effective_src="$src"
    if [[ "$file" == "opencode.json" ]]; then
      customize_opencode_json "$src" "$staging"
      effective_src="$staging"
    fi

    cp "$effective_src" "$dst"
    ok "Deployed ${file} → ${dst}"
  done

  rm -f "$staging"
  _STAGING_FILE=""
}

prompt_install_type() {
  if [[ -n "$INSTALL_TYPE" ]]; then
    case "$(echo "$INSTALL_TYPE" | tr '[:upper:]' '[:lower:]')" in
      terminal|cli|1) INSTALL_TYPE="terminal" ;;
      desktop|gui|app|2) INSTALL_TYPE="desktop" ;;
      both|all|3) INSTALL_TYPE="both" ;;
      *)
        warn "Unknown OPENCODE_INSTALL_TYPE '${INSTALL_TYPE}', defaulting to 'terminal'."
        INSTALL_TYPE="terminal"
        ;;
    esac
    return 0
  fi

  if [[ "$NON_INTERACTIVE" -eq 1 || ! -t 0 ]]; then
    info "Non-interactive mode: defaulting to Terminal installation."
    INSTALL_TYPE="terminal"
    return 0
  fi

  echo ""
  info "What type of OpenCode installation would you like?"
  echo "  1) Terminal (CLI) [default]"
  echo "  2) Desktop (GUI App)"
  echo "  3) Both"
  local choice=""
  read -r -p "Enter choice [1-3, default: 1]: " choice || true
  case "${choice:-1}" in
    2|[dD]|[dD][eE][sS][kK][tT][oO][pP])
      INSTALL_TYPE="desktop"
      ;;
    3|[bB]|[bB][oO][tT][hH])
      INSTALL_TYPE="both"
      ;;
    *)
      INSTALL_TYPE="terminal"
      ;;
  esac
}

main() {
  MODIFIED_RC_FILES=()
  SECRETS_SAVED_THIS_RUN=0

  # Flags (also documented in README): --non-interactive uses credential
  # values from the environment instead of prompting; --skip-mcp skips the
  # MCP credential step entirely; --type/--terminal/--desktop/--both select
  # installation targets.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --skip-mcp)
        SKIP_MCP=1
        shift
        ;;
      --type)
        if [[ $# -ge 2 ]]; then
          INSTALL_TYPE="$2"
          shift 2
        else
          err "--type requires an argument (terminal, desktop, or both)"
        fi
        ;;
      --type=*)
        INSTALL_TYPE="${1#*=}"
        shift
        ;;
      --terminal)
        INSTALL_TYPE="terminal"
        shift
        ;;
      --desktop)
        INSTALL_TYPE="desktop"
        shift
        ;;
      --both)
        INSTALL_TYPE="both"
        shift
        ;;
      -h|--help)
        echo "Usage: ./install.sh [options]"
        echo ""
        echo "Options:"
        echo "  --type <type>      Install type: 'terminal', 'desktop', or 'both'."
        echo "  --terminal         Install OpenCode Terminal (CLI) only."
        echo "  --desktop          Install OpenCode Desktop (GUI App) only."
        echo "  --both             Install both Terminal and Desktop."
        echo "  --non-interactive  Read GITHUB_PAT from the environment; never prompt."
        echo "  --skip-mcp         Skip MCP credential prompts entirely."
        echo "  -h, --help         Show this help message."
        return 0
        ;;
      *)
        warn "Unknown argument: $1 (ignored)"
        shift
        ;;
    esac
  done
  if [[ "$SKIP_MCP" -eq 1 ]]; then
    NON_INTERACTIVE=1
  fi

  echo ""
  printf "${CYAN}╔══════════════════════════════════════╗${NC}\n"
  printf "${CYAN}║       OpenCode Installer Script      ║${NC}\n"
  printf "${CYAN}╚══════════════════════════════════════╝${NC}\n"
  echo ""

  local os
  os="$(detect_os)"
  info "Detected OS: ${os}"

  prompt_install_type

  if [[ "$INSTALL_TYPE" == "terminal" || "$INSTALL_TYPE" == "both" ]]; then
    local method
    method="$(detect_install_method "$os")"
    info "Install method: ${method}"
    install_opencode "$method"
  fi

  if [[ "$INSTALL_TYPE" == "desktop" || "$INSTALL_TYPE" == "both" ]]; then
    download_and_install_desktop "$os"
  fi

  local cfg_dir
  cfg_dir="$(config_dir "$os")"
  deploy_configs "$cfg_dir"

  echo ""
  ok "★ OpenCode setup complete!"
  echo ""
  echo "Next steps:"
  echo ""
  echo "  1. Log in to the provider(s) you want to use:"
  echo "     \$ opencode auth login"
  echo ""
  echo "  2. Refresh the models OpenCode can see:"
  echo "     \$ opencode models"
  echo ""
  echo "  3. Review your deployed configuration:"
  echo "     ${cfg_dir}/opencode.json"
  echo "     ${cfg_dir}/oh-my-opencode-slim.json"
  echo ""
  if [[ "$INSTALL_TYPE" == "desktop" ]]; then
    echo "  4. Open OpenCode Desktop to get started."
  else
    echo "  4. Start OpenCode:"
    echo "     \$ opencode"
  fi
  echo ""
  echo "  5. Verify MCP servers (optional):"
  echo "     \$ opencode mcp list"
  echo ""

  print_path_next_steps

  if [[ "${SECRETS_SAVED_THIS_RUN:-0}" -eq 1 ]] && [[ -n "${GITHUB_PAT:-}" ]]; then
    # This installer session already has the new secrets exported, so a
    # restart from here hands them to the background service directly —
    # no need to reload the shell first.
    # Gated on SECRETS_SAVED_THIS_RUN so merely-inherited env vars (this
    # run saved nothing, e.g. skipped prompts or non-interactive CI with
    # pre-existing env) never trigger an automatic restart.
    info "MCP secrets are exported in this session — restarting the background service so it picks them up."
    if command -v opencode &>/dev/null && opencode service restart; then
      ok "opencode service restarted with the new credentials."
      info "Verifying MCP servers..."
      if ! opencode mcp list; then
        warn "Could not list MCP servers — run 'opencode mcp list' manually to verify."
      fi
    else
      warn "Could not restart opencode service automatically."
      warn "Run: source ~/.zshrc (or source ~/.bashrc), then opencode service restart && opencode mcp list"
    fi
    warn "This terminal still has the old env until you reload it: source ~/.zshrc (or source ~/.bashrc), or open a new terminal."
  elif [[ "$SKIP_MCP" -eq 0 ]] && [[ -n "${GITHUB_PAT:-}" ]]; then
    # Secrets were inherited from the environment but this run saved
    # nothing new — do not auto-restart, print only the manual hint.
    warn "Run: source ~/.zshrc (or source ~/.bashrc), then opencode service restart && opencode mcp list"
  fi

  local answer=""
  if [[ "$NON_INTERACTIVE" -eq 1 || ! -t 0 ]]; then
    info "Skipping star prompt (non-interactive)."
  else
    read -r -p "★ Star the repo on GitHub? [Y/n] " answer || true
    case "${answer:-Y}" in
      [nN]|[nN][oO])
        ;;
      *)
        if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
          if gh api -X PUT "user/starred/HossamYoussof/opencode-config" --silent; then
            ok "Thanks for starring! ★"
          else
            warn "Couldn't star automatically via gh CLI."
          fi
        else
          warn "gh CLI not found or not signed in — couldn't star automatically."
        fi
        ;;
    esac
  fi
  echo ""
}

# Guard so sourcing this file (e.g. in tests) doesn't run the installer.
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  main "$@"
fi
