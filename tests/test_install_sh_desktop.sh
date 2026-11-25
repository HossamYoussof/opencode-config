#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/install.sh" --source-only 2>/dev/null || true

# Test get_desktop_download_url returns valid URL and filename
info="$(get_desktop_download_url "macos")"
url="$(echo "$info" | awk '{print $1}')"
filename="$(echo "$info" | awk '{print $2}')"

echo "Testing macOS desktop resolution:"
echo "URL: $url"
echo "Filename: $filename"

if [[ -z "$url" || "$url" != http* ]]; then
  echo "FAIL: Expected valid http(s) URL, got '$url'"
  exit 1
fi

if [[ "$filename" != *".dmg" ]]; then
  echo "FAIL: Expected .dmg filename for macOS, got '$filename'"
  exit 1
fi

# Test Linux desktop resolution
info_linux="$(get_desktop_download_url "linux")"
url_linux="$(echo "$info_linux" | awk '{print $1}')"
file_linux="$(echo "$info_linux" | awk '{print $2}')"
if [[ -z "$url_linux" || "$file_linux" != *".AppImage" ]]; then
  echo "FAIL: Expected .AppImage filename for Linux, got '$file_linux'"
  exit 1
fi

# Test Windows desktop resolution
info_win="$(get_desktop_download_url "windows")"
url_win="$(echo "$info_win" | awk '{print $1}')"
file_win="$(echo "$info_win" | awk '{print $2}')"
if [[ -z "$url_win" || "$file_win" != *".exe" ]]; then
  echo "FAIL: Expected .exe filename for Windows, got '$file_win'"
  exit 1
fi

# Test find_desktop_app and download_and_install_desktop skip behavior
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

# 1. macOS: OpenCode.app detected (system /Applications or $HOME/Applications) and skips download
mkdir -p "$tmp_home/Applications/OpenCode.app"
found_mac="$(HOME="$tmp_home" find_desktop_app "macos")"
if [[ "$found_mac" != "/Applications/OpenCode.app" && "$found_mac" != "$tmp_home/Applications/OpenCode.app" ]]; then
  echo "FAIL: Expected OpenCode.app path on macOS, got '$found_mac'"
  exit 1
fi

skip_out="$(HOME="$tmp_home" download_and_install_desktop "macos")"
if [[ "$skip_out" != *"Skipping download"* ]]; then
  echo "FAIL: Expected skip message when desktop app exists on macOS, got '$skip_out'"
  exit 1
fi

# 2. Linux: AppImage in $HOME/.local/bin detected
mkdir -p "$tmp_home/.local/bin"
touch "$tmp_home/.local/bin/opencode-desktop-linux-x86_64.AppImage"
found_linux="$(HOME="$tmp_home" PATH="/usr/bin:/bin" find_desktop_app "linux")"
if [[ "$found_linux" != "$tmp_home/.local/bin/opencode-desktop-linux-x86_64.AppImage" ]]; then
  echo "FAIL: Expected AppImage path, got '$found_linux'"
  exit 1
fi

# 3. Windows: OpenCode.exe in LOCALAPPDATA/Programs/OpenCode detected
mkdir -p "$tmp_home/AppData/Local/Programs/OpenCode"
touch "$tmp_home/AppData/Local/Programs/OpenCode/OpenCode.exe"
found_win="$(LOCALAPPDATA="$tmp_home/AppData/Local" PROGRAMFILES="$tmp_home/ProgramFiles" PROGRAMFILES_X86="$tmp_home/ProgramFilesX86" find_desktop_app "windows")"
if [[ "$found_win" != "$tmp_home/AppData/Local/Programs/OpenCode/OpenCode.exe" ]]; then
  echo "FAIL: Expected Windows OpenCode.exe path, got '$found_win'"
  exit 1
fi

# 4. Missing app returns non-zero
if HOME="$tmp_home/empty" LOCALAPPDATA="$tmp_home/empty" PROGRAMFILES="$tmp_home/empty" PROGRAMFILES_X86="$tmp_home/empty" find_desktop_app "windows" >/dev/null 2>&1; then
  echo "FAIL: Expected find_desktop_app to return non-zero when app is missing"
  exit 1
fi

echo "PASS: get_desktop_download_url and find_desktop_app tests passed."
