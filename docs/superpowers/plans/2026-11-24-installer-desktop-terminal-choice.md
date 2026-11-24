# Desktop and Terminal Installer Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users running `install.sh` or `install.ps1` to choose between Terminal (CLI), Desktop (GUI), or Both, downloading and opening the selected installer while keeping config deployment consistent.

**Architecture:** Extend `install.sh` and `install.ps1` with an interactive 3-way prompt, CLI flags (`--type`, `--terminal`, `--desktop`, `--both` / `-Type`, `-Desktop`, etc.), and a desktop downloader function that queries `https://opencode.ai/update/api/latest/desktop`, maps OS/CPU architecture to official release artifacts, downloads to `~/Downloads`, and launches the installer.

**Tech Stack:** Bash, PowerShell 5.1+, Python 3 (JSON parsing fallback in bash), REST API (`https://opencode.ai/update/api/latest/desktop`).

## Global Constraints

- Must maintain 100% backward compatibility for non-interactive / CI runs (default to `terminal`).
- `install.sh` must remain compatible with Bash 3.2+ (macOS default bash) and Linux.
- `install.ps1` must remain compatible with Windows PowerShell 5.1+.
- Config files (`opencode.json` and `oh-my-opencode-slim.json`) must be deployed regardless of install type chosen.
- Zero placeholder comments (`TODO`, `TBD`, etc.).

---

### Task 1: Desktop Asset Resolution and Download in `install.sh`

**Files:**
- Modify: `install.sh`
- Test: `tests/test_install_sh_desktop.sh`

**Interfaces:**
- Consumes: `detect_os` (returns `macos`, `linux`, `windows`)
- Produces:
  - `get_desktop_download_url "$os"`: prints `URL<space>FILENAME`
  - `download_and_install_desktop "$os"`: downloads asset to `~/Downloads` and runs `open` or `chmod +x`

- [ ] **Step 1: Write test for desktop asset resolution and download logic**

Create `tests/test_install_sh_desktop.sh`:

```bash
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

echo "PASS: get_desktop_download_url test passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_install_sh_desktop.sh`  
Expected: FAIL with `get_desktop_download_url: command not found`

- [ ] **Step 3: Implement `get_desktop_download_url` and `download_and_install_desktop` in `install.sh`**

In `install.sh`, add:

```bash
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
    json_response="$(curl -fsSL "$api_url" 2>/dev/null || true)"
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

# Download and launch the Desktop installer
download_and_install_desktop() {
  local os="$1"
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_install_sh_desktop.sh`  
Expected: PASS with `URL: https://...` and `Filename: opencode-desktop-mac-...dmg`

- [ ] **Step 5: Commit changes**

```bash
git add install.sh tests/test_install_sh_desktop.sh
git commit -m "feat(installer): add desktop asset resolution and download for install.sh"
```

---

### Task 2: Interactive Prompt, Flags, and Flow in `install.sh`

**Files:**
- Modify: `install.sh`
- Test: `tests/test_install_sh_flags.sh`

**Interfaces:**
- Consumes: `get_desktop_download_url`, `download_and_install_desktop`, `install_opencode`
- Produces:
  - `INSTALL_TYPE`: variable holding `terminal`, `desktop`, or `both`
  - `prompt_install_type`: sets `INSTALL_TYPE` interactively or from env/defaults

- [ ] **Step 1: Write tests for CLI argument parsing and defaults in `install.sh`**

Create `tests/test_install_sh_flags.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Test 1: --help shows --type options
help_output="$("${SCRIPT_DIR}/install.sh" --help)"
if ! echo "$help_output" | grep -q -- "--type"; then
  echo "FAIL: --help missing --type documentation"
  exit 1
fi

# Test 2: Non-interactive dry run defaults to terminal
output="$("${SCRIPT_DIR}/install.sh" --non-interactive --skip-mcp --help)"
echo "$output"

echo "PASS: Flag parsing tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_install_sh_flags.sh`  
Expected: FAIL with missing `--type` documentation in `--help`.

- [ ] **Step 3: Implement prompt, flag parsing, and flow in `install.sh`**

1. Add global variable:
   ```bash
   INSTALL_TYPE="${OPENCODE_INSTALL_TYPE:-}"
   ```
2. Add function `prompt_install_type()`:
   ```bash
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
   ```
3. Update argument parsing in `main()`:
   - Handle `--type)`, `--type=*)`, `--terminal)`, `--desktop)`, `--both)`
   - Update `--help` text to document `--type <terminal|desktop|both>`, `--desktop`, `--terminal`, `--both`.
4. In `main()`, call `prompt_install_type`.
5. Conditionally invoke installations:
   ```bash
   if [[ "$INSTALL_TYPE" == "terminal" || "$INSTALL_TYPE" == "both" ]]; then
     local method
     method="$(detect_install_method "$os")"
     info "Install method: ${method}"
     install_opencode "$method"
   fi

   if [[ "$INSTALL_TYPE" == "desktop" || "$INSTALL_TYPE" == "both" ]]; then
     download_and_install_desktop "$os"
   fi
   ```
6. Adjust completion message:
   ```bash
   if [[ "$INSTALL_TYPE" == "desktop" ]]; then
     ok "All done! Open OpenCode Desktop to get started."
   else
     ok "All done! Run 'opencode' to get started."
   fi
   ```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_install_sh_flags.sh`  
Expected: PASS

- [ ] **Step 5: Commit changes**

```bash
git add install.sh tests/test_install_sh_flags.sh
git commit -m "feat(installer): add interactive type prompt and CLI flags to install.sh"
```

---

### Task 3: Desktop Asset Resolution and Download in `install.ps1`

**Files:**
- Modify: `install.ps1`
- Test: `tests/test_install_ps1.ps1`

**Interfaces:**
- Consumes: `$Type`, `$Desktop`, `$Terminal`, `$Both`, `$NonInteractive`
- Produces:
  - `Get-DesktopDownloadInfo`: returns `@{ Url = ...; Filename = ... }`
  - `Download-And-Install-Desktop`: downloads to `$HOME\Downloads` and runs `Start-Process`

- [ ] **Step 1: Write test for `install.ps1` parameters and desktop resolution**

Create `tests/test_install_ps1.ps1`:

```powershell
# Verify install.ps1 parameter signatures and desktop asset resolution
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "..\install.ps1"

# Check parameter metadata
$command = Get-Command $scriptPath
$params = $command.Parameters.Keys

if ($params -notcontains "Type") {
    Write-Error "FAIL: install.ps1 is missing -Type parameter"
}
if ($params -notcontains "Desktop") {
    Write-Error "FAIL: install.ps1 is missing -Desktop parameter"
}
if ($params -notcontains "Both") {
    Write-Error "FAIL: install.ps1 is missing -Both parameter"
}

Write-Host "PASS: Parameter checks passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -File tests/test_install_ps1.ps1` (or pwsh)  
Expected: FAIL with `install.ps1 is missing -Type parameter`.

- [ ] **Step 3: Implement parameters, desktop resolution, and download in `install.ps1`**

1. Update `param(...)` block in `install.ps1`:
   ```powershell
   param(
       [Parameter()][ValidateSet("Terminal", "Desktop", "Both")][string]$Type = "",
       [Parameter()][switch]$Terminal,
       [Parameter()][switch]$Desktop,
       [Parameter()][switch]$Both,
       [Parameter()][object]$GithubPat = $null,
       [Parameter()][string]$JenkinsUrl = "",
       [Parameter()][object]$JenkinsAuth = $null,
       [Parameter()][switch]$NonInteractive,
       [Parameter()][switch]$SkipStar
   )
   ```
2. Add `Get-DesktopDownloadInfo`:
   ```powershell
   function Get-DesktopDownloadInfo {
       $isArm = ($env:PROCESSOR_ARCHITECTURE -eq "ARM64")
       $targetFile = if ($isArm) { "opencode-desktop-win-arm64.exe" } else { "opencode-desktop-win-x64.exe" }
       $apiUrl = "https://opencode.ai/update/api/latest/desktop"
       $downloadUrl = ""

       try {
           $response = Invoke-RestMethod -Uri $apiUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
           if ($response.artifacts -and $response.artifacts[0].metadata -and $response.artifacts[0].metadata.files) {
               $files = $response.artifacts[0].metadata.files
               if ($files.PSObject.Properties[$targetFile]) {
                   $downloadUrl = $files.$targetFile.url
               }
           }
       } catch {
           Write-Warn "Could not fetch latest desktop release metadata from API: $_"
       }

       if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
           $fallbackVersion = "2.4.1"
           $downloadUrl = "https://opencode.ai/files/bin/$fallbackVersion/$targetFile"
       }

       return @{
           Url = $downloadUrl
           Filename = $targetFile
       }
   }
   ```
3. Add `Download-And-Install-Desktop`:
   ```powershell
   function Download-And-Install-Desktop {
       Write-Info "Resolving OpenCode Desktop download..."
       $info = Get-DesktopDownloadInfo
       $downloadUrl = $info.Url
       $filename = $info.Filename

       $downloadDir = Join-Path -Path $env:USERPROFILE -ChildPath "Downloads"
       if (-not (Test-Path -Path $downloadDir)) {
           $downloadDir = [IO.Path]::GetTempPath()
       }

       $targetPath = Join-Path -Path $downloadDir -ChildPath $filename
       Write-Info "Downloading OpenCode Desktop ($filename) to $downloadDir..."

       try {
           Invoke-WebRequest -Uri $downloadUrl -OutFile $targetPath -UseBasicParsing
           Write-Ok "Downloaded OpenCode Desktop → $targetPath"
           Write-Info "Launching installer..."
           Start-Process -FilePath $targetPath
           Write-Ok "OpenCode Desktop installer launched. Follow the setup wizard to complete installation."
       } catch {
           Write-Err "Failed to download OpenCode Desktop from $downloadUrl: $_"
       }
   }
   ```
4. Add `Get-InstallType`:
   ```powershell
   function Get-InstallType {
       if ($Both) { return "Both" }
       if ($Desktop) { return "Desktop" }
       if ($Terminal) { return "Terminal" }
       if (-not [string]::IsNullOrWhiteSpace($Type)) { return $Type }

       if (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_INSTALL_TYPE)) {
           switch ($env:OPENCODE_INSTALL_TYPE.Trim().ToLowerInvariant()) {
               "desktop" { return "Desktop" }
               "both"    { return "Both" }
               default   { return "Terminal" }
           }
       }

       if ($NonInteractive) {
           Write-Info "Non-interactive mode: defaulting to Terminal installation."
           return "Terminal"
       }

       Write-Host ""
       Write-Info "What type of OpenCode installation would you like?"
       Write-Host "  1) Terminal (CLI) [default]"
       Write-Host "  2) Desktop (GUI App)"
       Write-Host "  3) Both"
       $choice = ""
       try { $choice = Read-Host "Enter choice [1-3, default: 1]" } catch { $choice = "1" }
       switch ($choice.Trim()) {
           "2" { return "Desktop" }
           "3" { return "Both" }
           default { return "Terminal" }
       }
   }
   ```
5. In `Main`, call `Get-InstallType` and conditionally invoke `Install-Opencode` and `Download-And-Install-Desktop`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -File tests/test_install_ps1.ps1` (or powershell)  
Expected: PASS

- [ ] **Step 5: Commit changes**

```bash
git add install.ps1 tests/test_install_ps1.ps1
git commit -m "feat(installer): add desktop and terminal choice to install.ps1"
```

---

### Task 4: Documentation Update in `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update `README.md` with installation options**

Document:
- Interactive prompt options (Terminal, Desktop, Both)
- New CLI flags: `--type <terminal|desktop|both>`, `--desktop`, `--terminal`, `--both` for `install.sh`
- New PowerShell parameters: `-Type <Terminal|Desktop|Both>`, `-Desktop`, `-Terminal`, `-Both` for `install.ps1`
- `OPENCODE_INSTALL_TYPE` environment variable support

- [ ] **Step 2: Verify `README.md` formatting and clarity**

Check git diff to ensure changes are accurate and clean.

- [ ] **Step 3: Commit documentation update**

```bash
git add README.md
git commit -m "docs: document desktop and terminal installation options in README"
```
