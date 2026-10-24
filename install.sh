#!/usr/bin/env bash
set -euo pipefail

# NOTE: For native Windows (PowerShell), use install.ps1 instead.
# This script works on macOS, Linux, and Windows (via WSL/Git Bash/MSYS2).

# OpenCode Installer
# Installs opencode and deploys opencode.json + oh-my-opencode-slim.json
# to the global config directory for the current OS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILES=("opencode.json" "oh-my-opencode-slim.json" "opencode-mem.jsonc")

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

# Jenkins URL must look like http(s):// when provided.
_valid_jenkins_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

# Trim leading/trailing whitespace without spawning sed/awk.
_trim_ws() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# Strip a leading "Basic " prefix (case-insensitive) after trimming.
# A bare "Basic" with no credentials is treated as empty.
_strip_basic_prefix() {
  local v
  v="$(_trim_ws "$1")"
  case "$v" in
    [Bb][Aa][Ss][Ii][Cc])
      printf '%s' ""
      return 0
      ;;
    [Bb][Aa][Ss][Ii][Cc][[:space:]]*)
      v="${v#*[[:space:]]}"
      v="$(_trim_ws "$v")"
      ;;
  esac
  printf '%s' "$v"
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

customize_opencode_json() {
  local src_file="$1"
  local staging_file="$2"

  cp "$src_file" "$staging_file"

  # Secrets may come from the environment (non-interactive use):
  # GITHUB_PAT, JENKINS_BASIC_AUTH, and the non-secret JENKINS_URL.
  local github_pat="${GITHUB_PAT:-}" jenkins_url="${JENKINS_URL:-}" jenkins_auth="${JENKINS_BASIC_AUTH:-}"
  local prompted=0

  if [[ "$SKIP_MCP" -eq 1 ]]; then
    info "Skipping MCP credential prompts (--skip-mcp)."
    github_pat=""; jenkins_url=""; jenkins_auth=""
    return 0
  elif [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    info "Non-interactive mode: using credential values from the environment (if set)."
  elif [[ ! -t 0 ]]; then
    info "No interactive input available — using credential values from the environment (if set)."
  else
    prompted=1
    local _pat="" _url="" _auth=""
    # Only prompt for values not already provided via the environment.
    if [[ -z "$github_pat" ]]; then
      read -r -s -p "GitHub PAT for MCP (optional, Enter to skip): " _pat || true
      printf '\n'
      github_pat="$_pat"
    fi
    if [[ -z "$jenkins_url" ]]; then
      read -r -p "Jenkins URL (optional, Enter to skip) [https://jenkins-host/mcp-server/mcp]: " _url || true
      jenkins_url="$_url"
    fi
    if [[ -z "$jenkins_auth" ]]; then
      read -r -p "Jenkins Basic auth value - user:token base64 WITHOUT 'Basic ' prefix (optional, Enter to skip): " _auth || true
      jenkins_auth="$_auth"
    fi
    _pat=""; _url=""; _auth=""
    unset _pat _url _auth
  fi

  # Light validation: warn-and-skip bad values instead of storing them.
  if _is_blank "$github_pat"; then
    github_pat=""
  fi
  if _is_blank "$jenkins_auth"; then
    jenkins_auth=""
  fi
  jenkins_url="$(_trim_ws "$jenkins_url")"
  if [[ -n "$jenkins_url" ]] && ! _valid_jenkins_url "$jenkins_url"; then
    warn "Ignoring Jenkins URL '${jenkins_url}' — it must start with http:// or https://."
    jenkins_url=""
  fi

  if [[ -z "${github_pat}" && -z "${jenkins_url}" && -z "${jenkins_auth}" ]]; then
    if [[ "$prompted" -eq 0 ]]; then
      info "No MCP credentials in the environment — skipping (re-run interactively or set GITHUB_PAT / JENKINS_URL / JENKINS_BASIC_AUTH to configure)."
    fi
    return 0
  fi

  # Persist raw secrets to shell rc + current session only (one pass per
  # rc file for all secrets). They are NEVER written into the deployed
  # opencode.json; the JSON keeps `Bearer {env:GITHUB_PAT}` /
  # `Basic {env:JENKINS_BASIC_AUTH}`.
  local normalized_auth=""
  if [[ -n "${jenkins_auth}" ]]; then
    normalized_auth="$(_strip_basic_prefix "${jenkins_auth}")"
    if _is_blank "$normalized_auth"; then
      warn "Ignoring Jenkins auth value — it is empty after trimming."
      normalized_auth=""
      jenkins_auth=""
    fi
  fi

  if [[ -n "${github_pat}" && -n "${normalized_auth}" ]]; then
    export GITHUB_PAT="${github_pat}"
    export JENKINS_BASIC_AUTH="${normalized_auth}"
    if persist_secrets_to_rc "GITHUB_PAT" "${github_pat}" "JENKINS_BASIC_AUTH" "${normalized_auth}"; then
      SECRETS_SAVED_THIS_RUN=1
      ok "Saved GITHUB_PAT to shell rc; config keeps {env:GITHUB_PAT}."
      ok "Saved JENKINS_BASIC_AUTH to shell rc; config keeps {env:JENKINS_BASIC_AUTH}."
    fi
  elif [[ -n "${github_pat}" ]]; then
    export GITHUB_PAT="${github_pat}"
    if persist_secret_to_rc "GITHUB_PAT" "${github_pat}"; then
      SECRETS_SAVED_THIS_RUN=1
      ok "Saved GITHUB_PAT to shell rc; config keeps {env:GITHUB_PAT}."
    fi
  elif [[ -n "${normalized_auth}" ]]; then
    export JENKINS_BASIC_AUTH="${normalized_auth}"
    if persist_secret_to_rc "JENKINS_BASIC_AUTH" "${normalized_auth}"; then
      SECRETS_SAVED_THIS_RUN=1
      ok "Saved JENKINS_BASIC_AUTH to shell rc; config keeps {env:JENKINS_BASIC_AUTH}."
    fi
  fi

  local jenkins_auth_provided=0
  if [[ -n "${normalized_auth}" ]]; then
    jenkins_auth_provided=1
  fi

  # Reduce exposure of raw secrets in this shell.
  github_pat=""
  jenkins_auth=""
  normalized_auth=""
  unset github_pat jenkins_auth normalized_auth

  # Only the non-secret Jenkins URL is patched into the staging JSON.
  if [[ -z "${jenkins_url}" && ${jenkins_auth_provided} -eq 0 ]]; then
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    warn "python3 not found — deploying opencode.json without patching Jenkins URL (secrets still saved to shell rc)."
    return 0
  fi

  JENKINS_URL="${jenkins_url}" JENKINS_AUTH_PROVIDED="${jenkins_auth_provided}" \
    python3 - "$staging_file" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
jurl = os.environ.get("JENKINS_URL", "").strip()
auth_provided = os.environ.get("JENKINS_AUTH_PROVIDED", "0") == "1"

with open(path) as f:
    data = json.load(f)

servers = data.setdefault("mcp", {}).setdefault("servers", {})

# Secrets are never written here; placeholders like
# `Bearer {env:GITHUB_PAT}` / `Basic {env:JENKINS_BASIC_AUTH}` stay as-is.
# Only the non-secret Jenkins URL is patched.
jenkins_provided = bool(jurl or auth_provided)
if jenkins_provided:
    jenkins = servers.setdefault("jenkins", {})
    if jurl:
        jenkins["url"] = jurl
    jenkins.pop("disabled", None)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

  if [[ -n "${jenkins_url}" || ${jenkins_auth_provided} -eq 1 ]]; then
    ok "Patched Jenkins MCP URL (enabled)."
  fi
}

customize_opencode_mem_json() {
  local src_file="$1"
  local staging_file="$2"

  cp "$src_file" "$staging_file"

  # Skip if --skip-mcp (reuse flag for all optional config)
  if [[ "$SKIP_MCP" -eq 1 ]]; then
    info "Skipping opencode-mem customization (--skip-mcp)."
    return 0
  elif [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    info "Non-interactive mode: using opencode-mem values from environment (if set)."
  elif [[ ! -t 0 ]]; then
    info "No interactive input available — using opencode-mem values from environment (if set)."
  else
    echo ""
    printf "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}  OpenCode Memory Plugin (opencode-mem) - Auto-Capture Setup${NC}\n"
    printf "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
    echo ""
    warn "IMPORTANT: Auto-capture does NOT work with free opencode/* models."
    warn "         You need a provider with an API key (Groq, OpenAI, Anthropic, etc.)"
    warn "         or a local Ollama instance."
    echo ""
    read -r -p "Enable auto-capture for memory plugin? [y/N] " _enable || true
    if [[ "${_enable:-}" =~ ^[yY]$ ]]; then
      local _provider="" _model="" _url="" _key=""
      
      echo ""
      echo "Available providers:"
      echo "  1) Groq (free tier, fast)           - openai-chat  - llama-3.3-70b-versatile - https://api.groq.com/openai/v1"
      echo "  2) OpenAI                           - openai-chat  - gpt-4o-mini              - https://api.openai.com/v1"
      echo "  3) Anthropic                        - anthropic    - claude-3-5-haiku-20241022 - https://api.anthropic.com/v1"
      echo "  4) Ollama (local)                   - openai-chat  - llama3.1                 - http://localhost:11434/v1"
      echo "  5) Custom"
      echo ""
      read -r -p "Select provider [1-5]: " _choice || true
      
      case "${_choice:-}" in
        1) _provider="openai-chat"; _model="llama-3.3-70b-versatile"; _url="https://api.groq.com/openai/v1" ;;
        2) _provider="openai-chat"; _model="gpt-4o-mini"; _url="https://api.openai.com/v1" ;;
        3) _provider="anthropic"; _model="claude-3-5-haiku-20241022"; _url="https://api.anthropic.com/v1" ;;
        4) _provider="openai-chat"; _model="llama3.1"; _url="http://localhost:11434/v1" ;;
        5)
          read -r -p "Provider type (openai-chat/anthropic/openai-responses/minimax/orcarouter/atlas-cloud): " _provider || true
          read -r -p "Model name: " _model || true
          read -r -p "API URL: " _url || true
          ;;
        *) _provider=""; _model=""; _url="" ;;
      esac
      
      if [[ -n "$_provider" && -n "$_model" && -n "$_url" ]]; then
        read -r -s -p "API Key (will be saved to shell rc as env var): " _key || true
        printf '\n'
        if [[ -n "$_key" ]]; then
          # Save API key to shell rc
          local _key_name="OPENCODE_MEM_API_KEY"
          export "${_key_name}=${_key}"
          if persist_secret_to_rc "${_key_name}" "${_key}"; then
            ok "Saved ${_key_name} to shell rc."
          fi
          
          # Update the staging JSON with python
          if command -v python3 &>/dev/null; then
            MEM_PROVIDER="${_provider}" MEM_MODEL="${_model}" MEM_URL="${_url}" MEM_KEY="${_key_name}" \
              python3 - "$staging_file" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
provider = os.environ.get("MEM_PROVIDER", "")
model = os.environ.get("MEM_MODEL", "")
url = os.environ.get("MEM_URL", "")
key_env = os.environ.get("MEM_KEY", "")

with open(path) as f:
    data = json.load(f)

# Enable auto-capture and configure
data["autoCaptureEnabled"] = True
data["memoryProvider"] = provider
data["memoryModel"] = model
data["memoryApiUrl"] = url
data["memoryApiKey"] = f"env://{key_env}"

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
            ok "Configured auto-capture with ${_provider}/${_model}"
          else
            warn "python3 not found — auto-capture config not applied (manual edit needed)."
          fi
        else
          warn "No API key provided — auto-capture not configured."
        fi
      else
        warn "Incomplete provider config — auto-capture not configured."
      fi
    else
      info "Auto-capture disabled (default). You can enable it later by editing ~/.config/opencode/opencode-mem.jsonc"
    fi
    unset _enable _choice _provider _model _url _key _key_name
  fi
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
    elif [[ "$file" == "opencode-mem.jsonc" ]]; then
      local mem_staging
      mem_staging="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/opencode-mem-staging-$$.jsonc")"
      customize_opencode_mem_json "$src" "$mem_staging"
      effective_src="$mem_staging"
    fi

    cp "$effective_src" "$dst"
    ok "Deployed ${file} → ${dst}"
    if [[ "$file" == "opencode-mem.jsonc" && -n "${mem_staging:-}" ]]; then
      rm -f "$mem_staging"
    fi
  done

  rm -f "$staging"
  _STAGING_FILE=""
}

main() {
  MODIFIED_RC_FILES=()
  SECRETS_SAVED_THIS_RUN=0

  # Flags (also documented in README): --non-interactive uses credential
  # values from the environment instead of prompting; --skip-mcp skips the
  # MCP credential step entirely.
  # NB: `for arg in "$@"` with zero args trips `set -u` on bash 3.2
  # (macOS system bash), so only iterate when args exist.
  if [[ $# -gt 0 ]]; then
    local arg
    for arg in "$@"; do
      case "$arg" in
        --non-interactive) NON_INTERACTIVE=1 ;;
        --skip-mcp) SKIP_MCP=1 ;;
        -h|--help)
          echo "Usage: ./install.sh [--non-interactive] [--skip-mcp]"
          echo ""
          echo "  --non-interactive  Read GITHUB_PAT / JENKINS_URL / JENKINS_BASIC_AUTH"
          echo "                     from the environment; never prompt."
          echo "  --skip-mcp         Skip MCP credential prompts entirely."
          return 0
          ;;
        *)
          warn "Unknown argument: ${arg} (ignored)"
          ;;
      esac
    done
  fi
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

  if [[ "${SECRETS_SAVED_THIS_RUN:-0}" -eq 1 ]] && [[ -n "${GITHUB_PAT:-}" || -n "${JENKINS_BASIC_AUTH:-}" ]]; then
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
  elif [[ "$SKIP_MCP" -eq 0 ]] && [[ -n "${GITHUB_PAT:-}" || -n "${JENKINS_BASIC_AUTH:-}" ]]; then
    # Secrets were inherited from the environment but this run saved
    # nothing new — do not auto-restart, print only the manual hint.
    warn "Run: source ~/.zshrc (or source ~/.bashrc), then opencode service restart && opencode mcp list"
  fi

  local answer=""
  if [[ "$NON_INTERACTIVE" -eq 1 || ! -t 0 ]]; then
    info "Skipping star prompt (non-interactive)."
  else
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
  fi
  echo ""
}

# Guard so sourcing this file (e.g. in tests) doesn't run the installer.
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  main "$@"
fi
