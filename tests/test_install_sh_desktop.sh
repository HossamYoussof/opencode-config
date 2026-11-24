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

echo "PASS: get_desktop_download_url test passed."
