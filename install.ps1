<#
.SYNOPSIS
    OpenCode Installer for native Windows (PowerShell).
.DESCRIPTION
    Installs opencode and deploys opencode.json + oh-my-opencode-slim.json
    to the global config directory.
#>

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$ConfigFiles = @("opencode.json", "oh-my-opencode-slim.json")

# ── Colours ──────────────────────────────────────────────────────────
$Cyan   = "Cyan"
$Green  = "Green"
$Yellow = "Yellow"
$Red    = "Red"

function Write-Info  { Write-Host "▸ $args" -ForegroundColor $Cyan }
function Write-Ok    { Write-Host "✔ $args" -ForegroundColor $Green }
function Write-Warn  { Write-Host "⚠ $args" -ForegroundColor $Yellow }
function Write-Err   { Write-Host "✘ $args" -ForegroundColor $Red; exit 1 }

# ── Determine global config directory ────────────────────────────────
function Get-ConfigDir {
    if (Test-Path -Path "$env:APPDATA\opencode") {
        return "$env:APPDATA\opencode"
    }
    if ($env:APPDATA) {
        return "$env:APPDATA\opencode"
    }
    return "$env:USERPROFILE\.config\opencode"
}

# ── Detect best install method ───────────────────────────────────────
function Get-InstallMethod {
    # 1 — winget (Windows Package Manager)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        return "winget"
    }
    # 2 — scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        return "scoop"
    }
    # 3 — choco (Chocolatey)
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        return "choco"
    }
    # 4 — npm
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        return "npm"
    }

    Write-Err "No supported install method found. Please install winget, scoop, choco, or npm first."
}

# ── Install opencode ─────────────────────────────────────────────────
function Install-Opencode {
    param([string]$Method)

    if (Get-Command opencode -ErrorAction SilentlyContinue) {
        $version = & opencode --version 2>$null
        if (-not $version) { $version = "unknown" }
        Write-Warn "opencode is already installed (version: $version). Skipping install."
        return
    }

    Write-Info "Installing opencode via ${Method}..."

    switch ($Method) {
        "winget" {
            winget install anomalyco.opencode
        }
        "scoop" {
            scoop install opencode
        }
        "choco" {
            choco install opencode
        }
        "npm" {
            npm install -g opencode-ai
        }
    }

    # Verify
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Write-Err "opencode installation failed. Check the output above."
    }

    $version = & opencode --version 2>$null
    if (-not $version) { $version = "installed" }
    Write-Ok "opencode installed: $version"
}

# ── Deploy config files ──────────────────────────────────────────────
function Deploy-Configs {
    param([string]$TargetDir)

    Write-Info "Config directory: $TargetDir"

    $null = New-Item -ItemType Directory -Path $TargetDir -Force

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"

    foreach ($file in $ConfigFiles) {
        $src = Join-Path -Path $ScriptDir -ChildPath $file
        $dst = Join-Path -Path $TargetDir -ChildPath $file

        if (-not (Test-Path -Path $src)) {
            Write-Err "Source file not found: $src"
        }

        if (Test-Path -Path $dst) {
            $backup = "${dst}.bak.${timestamp}"
            Copy-Item -Path $dst -Destination $backup
            Write-Warn "Existing $file backed up → $backup"
        }

        Copy-Item -Path $src -Destination $dst
        Write-Ok "Deployed $file → $dst"
    }
}

# ── Main ─────────────────────────────────────────────────────────────
function Main {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor $Cyan
    Write-Host "║       OpenCode Installer Script      ║" -ForegroundColor $Cyan
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor $Cyan
    Write-Host ""

    $cfgDir = Get-ConfigDir
    Write-Info "Config directory: $cfgDir"

    $method = Get-InstallMethod
    Write-Info "Install method: $method"

    # Step 1 — Install opencode
    Install-Opencode -Method $method

    # Step 2 — Deploy config files
    Deploy-Configs -TargetDir $cfgDir

    Write-Host ""
    Write-Ok "All done! Run 'opencode' to get started."
    Write-Host ""
}

# Entry point
Main
