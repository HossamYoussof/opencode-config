# Specification: Desktop and Terminal Installation Choice

**Date:** 2026-11-24  
**Status:** Approved  
**Files Affected:** `install.sh`, `install.ps1`, `README.md`

---

## 1. Overview & Objective

Enhance `install.sh` and `install.ps1` to prompt users to choose what type of OpenCode installation they want:
1. **Terminal (CLI / TUI)**
2. **Desktop (GUI App)**
3. **Both (CLI + Desktop)**

The installer downloads and executes/opens the appropriate platform packages based on the user's selection while maintaining full compatibility with non-interactive scripts and existing configuration deployment.

---

## 2. Requirements & Behavior

### 2.1 Interactive Selection
When executed interactively in a TTY, the installer displays:
```text
Select installation type:
  1) Terminal (CLI) [default]
  2) Desktop (GUI App)
  3) Both
Enter choice [1-3]: 
```
- Typing `1` or pressing `Enter` selects **Terminal**.
- Typing `2` selects **Desktop**.
- Typing `3` selects **Both**.
- Any unrecognized input defaults to **Terminal** with a short informational notice.

### 2.2 CLI Flags & Environment Variables
To support automated environments, scripting, and command-line preferences:
- **`install.sh`**:
  - `--type <terminal|desktop|both>`
  - `--terminal`, `--desktop`, `--both`
  - Environment variable fallback: `OPENCODE_INSTALL_TYPE`
- **`install.ps1`**:
  - `-Type <Terminal|Desktop|Both>`
  - `-Terminal`, `-Desktop`, `-Both`
  - Environment variable fallback: `$env:OPENCODE_INSTALL_TYPE`
- **Non-interactive behavior**:
  - In non-interactive mode (`--non-interactive` / `-NonInteractive` or when `stdin` is not a TTY):
    - If a type flag/env is specified, use it.
    - Otherwise, default to **Terminal** (preserves existing CI/CD and scripted installation behavior).

---

## 3. Desktop Asset Resolution & Download

### 3.1 Official API Endpoint
Desktop installers are resolved dynamically from OpenCode's official update API:
`https://opencode.ai/update/api/latest/desktop`

The JSON payload provides the latest release version and download URLs under `artifacts[0].metadata.files`:
- **macOS Apple Silicon (arm64):** `opencode-desktop-mac-arm64.dmg`
- **macOS Intel (x64 / x86_64):** `opencode-desktop-mac-x64.dmg`
- **Windows x64:** `opencode-desktop-win-x64.exe`
- **Windows arm64:** `opencode-desktop-win-arm64.exe`
- **Linux x86_64:** `opencode-desktop-linux-x86_64.AppImage` (or `.deb` when `dpkg` is present)
- **Linux arm64 / aarch64:** `opencode-desktop-linux-arm64.AppImage` (or `.deb` when `dpkg` is present)

### 3.2 Target Directory & Download Process
1. Downloads are placed in the user's `Downloads` folder:
   - macOS / Linux: `$HOME/Downloads` (or `$TMPDIR` / `/tmp` if `~/Downloads` is unavailable).
   - Windows: `[Environment]::GetFolderPath('UserProfile')\Downloads` (or `$env:TEMP` fallback).
2. Download tools:
   - `install.sh`: `curl -fL --progress-bar` (with fallback to `wget`).
   - `install.ps1`: `Invoke-WebRequest` / `Start-BitsTransfer` with status messages.

### 3.3 Launching the Desktop Installer
After download completes:
- **macOS:** Runs `open "$download_path"` to mount the `.dmg` in Finder, allowing the user to drag `OpenCode.app` into `/Applications`.
- **Windows:** Runs `Start-Process -FilePath "$downloadPath"` to open the Windows installer GUI.
- **Linux:** Adds executable permissions (`chmod +x "$download_path"`) to `.AppImage` and notifies user (or executes it if permitted); if `.deb`, offers to install via `dpkg -i` or opens file manager.

---

## 4. Terminal & Config Flow

- **Terminal Installation:**
  - Preserved exactly as existing logic (`install_opencode` via curl/npm/brew on `install.sh`, and npm on `install.ps1`).
- **Configuration Deployment (`deploy_configs`):**
  - Always runs regardless of choice (Terminal, Desktop, or Both).
  - OpenCode Desktop and CLI share the same configuration directory (`~/.config/opencode` on macOS/Linux, `%APPDATA%\opencode` on Windows), ensuring presets and MCP server settings apply immediately.
- **Service Restart:**
  - Background service restart (`opencode service restart`) is triggered only when Terminal or Both was chosen and `opencode` is on `PATH`.

---

## 5. Verification & Testing

1. **Bash Script Syntax & Flag Tests:**
   - Test `./install.sh --help` displays new `--type` options.
   - Test non-interactive default: `./install.sh --non-interactive --skip-mcp`.
   - Test desktop-only flag parse and URL resolution.
2. **PowerShell Script Syntax & Parameter Tests:**
   - Test `powershell -Command "Get-Help .\install.ps1"` or test syntax parsing.
   - Verify `-Type Desktop`, `-Type Terminal`, `-Type Both` and switch flags.
