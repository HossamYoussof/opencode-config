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

# Colours
$Cyan   = "Cyan"
$Green  = "Green"
$Yellow = "Yellow"
$Red    = "Red"

function Write-Info  { Write-Host "INFO: $args" -ForegroundColor $Cyan }
function Write-Ok    { Write-Host "OK: $args" -ForegroundColor $Green }
function Write-Warn  { Write-Host "WARN: $args" -ForegroundColor $Yellow }
function Write-Err   { Write-Host "ERROR: $args" -ForegroundColor $Red; exit 1 }

# Determine global config directory
function Get-ConfigDir {
    if ($env:APPDATA) {
        return "$env:APPDATA\opencode"
    }
    return "$env:USERPROFILE\.config\opencode"
}

# Detect install method.
# NOTE: For opencode v2, Windows package managers (winget/scoop/choco)
# install the old v1 build and are NOT supported. The only supported
# native-Windows method is npm.
function Get-InstallMethod {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        return "npm"
    }

    Write-Err "npm is required to install opencode v2 on Windows. Please install Node.js/npm from https://nodejs.org/ and re-run this script, OR use WSL and run: curl -fsSL https://opencode.ai/v2/install | bash"
}

# PATH handling: refresh session PATH + persist well-known dirs on User PATH
function Refresh-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($machine -and $user) {
        $env:PATH = $machine + ';' + $user
    } elseif ($machine) {
        $env:PATH = $machine
    } elseif ($user) {
        $env:PATH = $user
    }
}

function Ensure-OnPath {
    param([string]$Dir)

    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    $Dir = $Dir.Trim().TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    if (-not (Test-Path -Path $Dir)) { return }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $found = $false
    foreach ($p in ($userPath -split ';')) {
        if ($p.Trim().TrimEnd('\', '/') -ieq $Dir) { $found = $true }
    }
    if (-not $found) {
        if ([string]::IsNullOrWhiteSpace($userPath)) {
            $userPath = $Dir
        } else {
            $userPath = $userPath.TrimEnd(';') + ';' + $Dir
        }
        [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
        Write-Ok "Added to User PATH: $Dir"
    }

    $inSession = $false
    foreach ($p in ($env:PATH -split ';')) {
        if ($p.Trim().TrimEnd('\', '/') -ieq $Dir) { $inSession = $true }
    }
    if (-not $inSession) {
        $env:PATH = $Dir + ';' + $env:PATH
    }
}

function Ensure-InstallLocationsOnPath {
    $candidates = @()
    if ($env:USERPROFILE) {
        $candidates += "$env:USERPROFILE\scoop\shims"
        $candidates += "$env:USERPROFILE\.opencode\bin"
    }
    if ($env:APPDATA) {
        $candidates += "$env:APPDATA\npm"
    }
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        try {
            $prefix = (& npm config get prefix 2>$null | Out-String).Trim()
            if ($prefix -and (Test-Path -Path $prefix)) {
                $candidates += $prefix
            }
        } catch {
            Write-Warn "Could not determine npm prefix."
        }
    }
    foreach ($d in ($candidates | Select-Object -Unique)) {
        Ensure-OnPath $d
    }
}

# Install opencode
function Install-Opencode {
    param([string]$Method)

    if (Get-Command opencode -ErrorAction SilentlyContinue) {
        $version = & opencode --version 2>$null
        if (-not $version) { $version = "unknown" }
        Write-Warn "opencode is already installed (version: $version). Skipping install."
        Refresh-SessionPath
        Ensure-InstallLocationsOnPath
        return
    }

    Write-Info "Installing opencode via ${Method}..."

    switch ($Method) {
        "npm" {
            npm install -g @opencode/cli
        }
        default {
            Write-Err "Unsupported install method: $Method. opencode v2 on Windows requires npm (`npm install -g @opencode/cli`). Windows package managers (winget/scoop/choco) install v1 and are not supported."
        }
    }

    Write-Info "Refreshing PATH for the current session..."
    Refresh-SessionPath
    Ensure-InstallLocationsOnPath

    # Verify
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Write-Err "opencode not found on PATH after install. Restart your terminal, then check the install output above."
    }

    $version = & opencode --version 2>$null
    if (-not $version) { $version = "installed" }
    Write-Ok "opencode installed: $version"
}

# Deploy config files
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
            Write-Warn "Existing $file backed up to $backup"
        }

        Copy-Item -Path $src -Destination $dst
        Write-Ok "Deployed $file to $dst"
    }
}

# Main
function Main {
    Write-Host ""
    Write-Host "OpenCode Installer Script" -ForegroundColor $Cyan
    Write-Host ""

    $cfgDir = Get-ConfigDir
    Write-Info "Config directory: $cfgDir"

    $method = Get-InstallMethod
    Write-Info "Install method: $method"

    # Step 1 - Install opencode
    Install-Opencode -Method $method

    # Step 2 - Deploy config files
    Deploy-Configs -TargetDir $cfgDir

    Write-Host ""
    Write-Ok "All done! Run 'opencode' to get started."
    Write-Host ""

    $star = Read-Host "Star the repo on GitHub if you find it useful? [y/N]"
    if ($star -match '^[yY]') {
        $starred = $false
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if ($gh) {
            gh auth status 2>$null
            if ($LASTEXITCODE -eq 0) {
                gh api -X PUT "user/starred/HossamYoussof/opencode-config" --silent 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "Starred the repo."
                    $starred = $true
                }
            }
        }
        if (-not $starred) {
            Write-Warn "Couldn't star automatically - open the repo and star it manually."
        }
        Start-Process "https://github.com/HossamYoussof/opencode-config"
    }
    Write-Host ""
}

# Entry point
Main
