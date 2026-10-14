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

# Persist an MCP credential to the User environment without ever baking it
# into opencode.json. Never writes the value to the console.
function Save-McpSecretToUserEnv {
    param([string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return }
    $existing = [Environment]::GetEnvironmentVariable($Name, 'User')
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Warn "$Name already set in User env; update it manually via System settings if needed."
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $trimmed, 'User')
    Set-Item -Path ("Env:" + $Name) -Value $trimmed
    Write-Ok "Saved $Name to User environment (current session updated)."
}

# Convert a SecureString to plaintext for env persistence only.
# Caller must clear the returned plaintext ASAP. Never Write-Host it.
# PS 5.1 compatible.
function Convert-SecureStringToPlainText {
    param([System.Security.SecureString]$Secure)

    if ($null -eq $Secure) { return "" }
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ($null -eq $plain) { return "" }
        return $plain
    } catch {
        return ""
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

# Prompt for optional credentials and stage a customized opencode.json.
# All prompts are optional (Enter to skip). Never aborts the install.
function Get-CustomizedOpencodeJson {
    param([string]$SrcPath)

    try {
        if (-not (Test-Path -Path $SrcPath)) { return $SrcPath }

        $tempDir = [IO.Path]::GetTempPath()
        $staging = Join-Path -Path $tempDir -ChildPath ("opencode.staged." + $PID + ".json")
        Copy-Item -Path $SrcPath -Destination $staging -Force

        # Current Jenkins URL default (shown in the prompt).
        $defaultJenkinsUrl = "https://jenkins-host/mcp-server/mcp"
        try {
            $preview = Get-Content -Path $staging -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($preview.mcp -and $preview.mcp.servers -and $preview.mcp.servers.jenkins -and $preview.mcp.servers.jenkins.url) {
                $defaultJenkinsUrl = [string]$preview.mcp.servers.jenkins.url
            }
        } catch {
            # Ignore preview failures; patch step below will warn if JSON is invalid.
        }

        # Optional prompts. Empty/error just skips customization.
        # Secrets use SecureString so keystrokes are not echoed; Jenkins URL
        # is not secret and stays a normal Read-Host.
        $githubPat = ""
        $jenkinsUrl = ""
        $jenkinsAuth = ""
        $githubSecure = $null
        $jenkinsAuthSecure = $null
        try { $githubSecure = Read-Host "GitHub PAT (optional, Enter to skip)" -AsSecureString } catch { $githubSecure = $null }
        try { $jenkinsUrl = Read-Host ("Jenkins URL (optional, Enter to keep [$defaultJenkinsUrl])") } catch { $jenkinsUrl = "" }
        try { $jenkinsAuthSecure = Read-Host "Jenkins Basic auth value, user:token base64 WITHOUT 'Basic ' prefix (optional, Enter to skip)" -AsSecureString } catch { $jenkinsAuthSecure = $null }
        try {
            if ($null -ne $githubSecure) { $githubPat = Convert-SecureStringToPlainText -Secure $githubSecure }
        } catch { $githubPat = "" }
        try {
            if ($null -ne $jenkinsAuthSecure) { $jenkinsAuth = Convert-SecureStringToPlainText -Secure $jenkinsAuthSecure }
        } catch { $jenkinsAuth = "" }
        $githubSecure = $null
        $jenkinsAuthSecure = $null
        if ($null -eq $githubPat) { $githubPat = "" }
        if ($null -eq $jenkinsUrl) { $jenkinsUrl = "" }
        if ($null -eq $jenkinsAuth) { $jenkinsAuth = "" }

        $hasGithubPat = -not [string]::IsNullOrWhiteSpace($githubPat)
        $hasJenkinsUrl = -not [string]::IsNullOrWhiteSpace($jenkinsUrl)
        $hasJenkinsAuth = -not [string]::IsNullOrWhiteSpace($jenkinsAuth)

        if (-not $hasGithubPat -and -not $hasJenkinsUrl -and -not $hasJenkinsAuth) {
            Write-Info "No custom credentials entered; deploying opencode.json as-is."
            $githubPat = ""
            $jenkinsAuth = ""
            return $staging
        }

        try {
            $json = Get-Content -Path $staging -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warn "Could not parse opencode.json; deploying it unmodified."
            $githubPat = ""
            $jenkinsAuth = ""
            return $SrcPath
        }

        # Secrets are NEVER baked into JSON. Placeholders
        # (Bearer {env:GITHUB_PAT} / Basic {env:JENKINS_BASIC_AUTH}) stay as-is
        # in the template; raw values go to User env only.
        if ($hasGithubPat) {
            Save-McpSecretToUserEnv -Name 'GITHUB_PAT' -Value $githubPat
        }

        if ($hasJenkinsAuth) {
            $authValue = $jenkinsAuth.Trim()
            if ($authValue -imatch '^\s*Basic\s+(.+)$') {
                $authValue = $Matches[1].Trim()
            }
            Save-McpSecretToUserEnv -Name 'JENKINS_BASIC_AUTH' -Value $authValue
            $authValue = ""
        }

        if (($hasJenkinsUrl -or $hasJenkinsAuth) -and $json.mcp -and $json.mcp.servers -and $json.mcp.servers.jenkins) {
            if ($hasJenkinsUrl) {
                $json.mcp.servers.jenkins.url = $jenkinsUrl.Trim()
            }
            if ($json.mcp.servers.jenkins.PSObject.Properties['disabled']) {
                $null = $json.mcp.servers.jenkins.PSObject.Properties.Remove('disabled')
            }
        }

        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $staging -Encoding UTF8
        Write-Ok "Staged customized opencode.json."
        $githubPat = ""
        $jenkinsAuth = ""
        return $staging
    } catch {
        Write-Warn "Skipping credential customization; deploying opencode.json as-is."
        return $SrcPath
    }
}

# Deploy config files
function Deploy-Configs {
    param([string]$TargetDir)

    Write-Info "Config directory: $TargetDir"

    $null = New-Item -ItemType Directory -Path $TargetDir -Force

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"

    $opencodeSrc = Join-Path -Path $ScriptDir -ChildPath "opencode.json"
    $stagedOpencodeJson = Get-CustomizedOpencodeJson -SrcPath $opencodeSrc

    foreach ($file in $ConfigFiles) {
        $src = Join-Path -Path $ScriptDir -ChildPath $file
        if ($file -eq "opencode.json" -and $stagedOpencodeJson -and (Test-Path -Path $stagedOpencodeJson)) {
            $src = $stagedOpencodeJson
        }
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

    if ($stagedOpencodeJson -and ($stagedOpencodeJson -ne $opencodeSrc) -and (Test-Path -Path $stagedOpencodeJson)) {
        Remove-Item -Path $stagedOpencodeJson -ErrorAction SilentlyContinue
    }

    Write-Warn "If the opencode background service is running, it still has the old environment."
    Write-Info "Restart it with: opencode service restart ; then verify with: opencode mcp list"
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

    # The background opencode service keeps the old env after secrets are
    # saved; offer a guarded restart (never aborts the install).
    try {
        $restart = Read-Host "Restart opencode service now to pick up new credentials? [y/N]"
        if ($restart -match '^[yY]') {
            try {
                & opencode service restart
                Write-Ok "opencode service restarted."
                Write-Info "Verify with: opencode mcp list"
            } catch {
                Write-Warn "Could not restart opencode service automatically. Run 'opencode service restart' manually, then 'opencode mcp list' to verify."
            }
        } else {
            Write-Info "If the opencode background service is running, restart it manually: opencode service restart ; then verify with: opencode mcp list"
        }
    } catch {
        Write-Warn "If the opencode background service is running, restart it manually: opencode service restart ; then verify with: opencode mcp list"
    }

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
