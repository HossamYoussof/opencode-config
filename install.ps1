<#
.SYNOPSIS
    OpenCode Installer for native Windows (PowerShell).
.DESCRIPTION
    Installs opencode and deploys opencode.json + oh-my-opencode-slim.json
    to the global config directory.
.PARAMETER GithubPat
    Optional GitHub PAT (SecureString preferred, plain string accepted).
    Falls back to $env:GITHUB_PAT when omitted.
.PARAMETER JenkinsUrl
    Optional Jenkins MCP URL (must look like http(s)://...).
    Falls back to $env:JENKINS_URL when omitted.
.PARAMETER JenkinsAuth
    Optional Jenkins Basic auth value (SecureString preferred, plain string
    accepted, WITHOUT the 'Basic ' prefix - prefix is stripped if present).
    Falls back to $env:JENKINS_BASIC_AUTH (or $env:JENKINS_AUTH) when omitted.
.PARAMETER NonInteractive
    Skip all interactive prompts (credentials + star). Param/env values are
    still honored; missing values are skipped with an info message.
.PARAMETER SkipStar
    Skip only the "star the repo" prompt.
.EXAMPLE
    .\install.ps1 -NonInteractive
.EXAMPLE
    .\install.ps1 -JenkinsUrl "https://jenkins.example.com/mcp-server/mcp" -NonInteractive
#>

#Requires -Version 5.1

param(
    [Parameter()][object]$GithubPat = $null,
    [Parameter()][string]$JenkinsUrl = "",
    [Parameter()][object]$JenkinsAuth = $null,
    [Parameter()][switch]$NonInteractive,
    [Parameter()][switch]$SkipStar
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$ConfigFiles = @("opencode.json", "oh-my-opencode-slim.json", "opencode-mem.jsonc")

# Tracks whether THIS run persisted any MCP secret to User env.
# Set to $true only inside Save-McpSecretToUserEnv when a new/changed
# value is actually written. Gates the auto service-restart below.
$script:SavedSecrets = $false

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
    $candidates = @($candidates | Select-Object -Unique)
    if ($candidates.Count -eq 0) { return }

    # Single User-PATH registry read; append missing dirs in memory; single
    # write. Session PATH is updated inline (no registry cost).
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $known = @()
    foreach ($p in ($userPath -split ';')) {
        $t = $p.Trim().TrimEnd('\', '/')
        if ($t) { $known += $t.ToLowerInvariant() }
    }
    $added = @()
    foreach ($d in $candidates) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $dir = $d.Trim().TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (-not (Test-Path -Path $dir)) { continue }
        if ($known -notcontains $dir.ToLowerInvariant()) {
            if ([string]::IsNullOrWhiteSpace($userPath)) {
                $userPath = $dir
            } else {
                $userPath = $userPath.TrimEnd(';') + ';' + $dir
            }
            $known += $dir.ToLowerInvariant()
            $added += $dir
        }
        $inSession = $false
        foreach ($p in ($env:PATH -split ';')) {
            if ($p.Trim().TrimEnd('\', '/') -ieq $dir) { $inSession = $true; break }
        }
        if (-not $inSession) {
            $env:PATH = $dir + ';' + $env:PATH
        }
    }
    if ($added.Count -gt 0) {
        [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
        foreach ($a in $added) {
            Write-Ok "Added to User PATH: $a"
        }
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
    param([string]$Name, [string]$Value, [switch]$NonInteractive)

    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return }
    $existing = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($existing -ceq $trimmed) {
        Write-Ok "$Name already up to date in User environment."
        Set-Item -Path ("Env:" + $Name) -Value $trimmed -ErrorAction SilentlyContinue
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        if (-not $NonInteractive) {
            $answer = ""
            try { $answer = Read-Host ("Overwrite existing $Name" + "? [y/N]") } catch { $answer = "" }
            if ($answer -notmatch '^[yY]') {
                Write-Info ("Keeping existing $Name" + "; skipped overwrite.")
                Set-Item -Path ("Env:" + $Name) -Value $existing -ErrorAction SilentlyContinue
                return
            }
        }
    }
    [Environment]::SetEnvironmentVariable($Name, $trimmed, 'User')
    Set-Item -Path ("Env:" + $Name) -Value $trimmed
    $script:SavedSecrets = $true
    if ([string]::IsNullOrWhiteSpace($existing)) {
        Write-Ok "Saved $Name to User environment (current session updated)."
    } else {
        Write-Ok "Updated $Name in User environment (old value replaced; current session updated)."
    }
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

# Normalize a -GithubPat/-JenkinsAuth argument that may be a SecureString or
# a plain string. Returns plaintext the caller must clear ASAP. Never logs it.
function ConvertTo-PlainSecret {
    param([object]$Secret)

    if ($null -eq $Secret) { return "" }
    if ($Secret -is [System.Security.SecureString]) {
        return Convert-SecureStringToPlainText -Secure $Secret
    }
    if ($Secret -is [string]) { return $Secret }
    return [string]$Secret
}

# Single place for trim + 'Basic ' prefix stripping (auth values are stored
# WITHOUT the prefix). Returns "" for null/empty.
function Normalize-BasicAuthValue {
    param([string]$Value)

    if ($null -eq $Value) { return "" }
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return "" }
    if ($trimmed -imatch '^\s*Basic\s+(.+)$') {
        $trimmed = $Matches[1].Trim()
    } elseif ($trimmed -ieq 'Basic') {
        # Bare "Basic" with no credentials is not a valid auth value.
        return ""
    }
    return $trimmed
}

# Jenkins URL sanity check (non-empty http(s) URL). Not a reachability test.
function Test-HttpUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    return ($Url.Trim() -match '^https?://\S')
}

# Prompt for optional credentials and stage a customized opencode.json.
# All prompts are optional (Enter to skip). Never aborts the install.
# Secrets go to User env only; the JSON keeps {env:...} placeholders.
function Get-CustomizedOpencodeJson {
    param(
        [string]$SrcPath,
        [object]$GithubPatParam = $null,
        [string]$JenkinsUrlParam = "",
        [object]$JenkinsAuthParam = $null,
        [switch]$NonInteractive
    )

    if (-not (Test-Path -Path $SrcPath)) { return $SrcPath }

    $staging = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("opencode.staged." + $PID + ".json")
    $keepStaging = $false
    # Plaintext secrets: cleared in finally + right after saving. Never logged.
    $githubPat = ""
    $jenkinsUrl = ""
    $jenkinsAuth = ""
    try {
        Copy-Item -Path $SrcPath -Destination $staging -Force

        # Parse ONCE; reuse for the prompt default and the patch below.
        try {
            $json = Get-Content -Path $staging -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warn "Could not parse opencode.json; deploying it unmodified."
            return $SrcPath
        }

        # Current Jenkins URL default (shown in the prompt).
        $defaultJenkinsUrl = "https://jenkins-host/mcp-server/mcp"
        if ($json.mcp -and $json.mcp.servers -and $json.mcp.servers.jenkins -and $json.mcp.servers.jenkins.url) {
            $defaultJenkinsUrl = [string]$json.mcp.servers.jenkins.url
        }

        # Resolve values: explicit param > process env > interactive prompt.
        $githubPat = ConvertTo-PlainSecret -Secret $GithubPatParam
        if ([string]::IsNullOrWhiteSpace($githubPat) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_PAT)) {
            $githubPat = $env:GITHUB_PAT
            Write-Info "Using GITHUB_PAT from process environment."
        }

        if ($null -eq $JenkinsUrlParam) { $JenkinsUrlParam = "" }
        $jenkinsUrl = $JenkinsUrlParam.Trim()
        if ([string]::IsNullOrWhiteSpace($jenkinsUrl)) {
            if (-not [string]::IsNullOrWhiteSpace($env:JENKINS_URL)) {
                $jenkinsUrl = $env:JENKINS_URL.Trim()
                Write-Info "Using JENKINS_URL from process environment."
            } elseif (-not [string]::IsNullOrWhiteSpace($env:JENKINS_MCP_URL)) {
                $jenkinsUrl = $env:JENKINS_MCP_URL.Trim()
                Write-Info "Using JENKINS_MCP_URL from process environment."
            }
        }

        $jenkinsAuth = ConvertTo-PlainSecret -Secret $JenkinsAuthParam
        if ([string]::IsNullOrWhiteSpace($jenkinsAuth)) {
            if (-not [string]::IsNullOrWhiteSpace($env:JENKINS_BASIC_AUTH)) {
                $jenkinsAuth = $env:JENKINS_BASIC_AUTH
                Write-Info "Using JENKINS_BASIC_AUTH from process environment."
            } elseif (-not [string]::IsNullOrWhiteSpace($env:JENKINS_AUTH)) {
                $jenkinsAuth = $env:JENKINS_AUTH
                Write-Info "Using JENKINS_AUTH from process environment."
            }
        }

        # Optional prompts. Empty/error just skips customization.
        # Secrets use SecureString so keystrokes are not echoed; Jenkins URL
        # is not secret and stays a normal Read-Host.
        if ([string]::IsNullOrWhiteSpace($githubPat)) {
            if ($NonInteractive) {
                Write-Info "Skipping GitHub PAT prompt (non-interactive); pass -GithubPat or set GITHUB_PAT to include it."
            } else {
                try {
                    $githubSecure = Read-Host "GitHub PAT (optional, Enter to skip)" -AsSecureString
                    if ($null -ne $githubSecure) { $githubPat = Convert-SecureStringToPlainText -Secure $githubSecure }
                    $githubSecure = $null
                } catch { $githubPat = "" }
            }
        }
        if ([string]::IsNullOrWhiteSpace($jenkinsUrl)) {
            if ($NonInteractive) {
                Write-Info "Skipping Jenkins URL prompt (non-interactive); pass -JenkinsUrl or set JENKINS_URL to include it."
            } else {
                try { $jenkinsUrl = Read-Host ("Jenkins URL (optional, Enter to keep [$defaultJenkinsUrl])") } catch { $jenkinsUrl = "" }
            }
        }
        if ([string]::IsNullOrWhiteSpace($jenkinsAuth)) {
            if ($NonInteractive) {
                Write-Info "Skipping Jenkins auth prompt (non-interactive); pass -JenkinsAuth or set JENKINS_BASIC_AUTH to include it."
            } else {
                try {
                    $jenkinsAuthSecure = Read-Host "Jenkins Basic auth value, user:token base64 WITHOUT 'Basic ' prefix (optional, Enter to skip)" -AsSecureString
                    if ($null -ne $jenkinsAuthSecure) { $jenkinsAuth = Convert-SecureStringToPlainText -Secure $jenkinsAuthSecure }
                    $jenkinsAuthSecure = $null
                } catch { $jenkinsAuth = "" }
            }
        }
        if ($null -eq $githubPat) { $githubPat = "" } else { $githubPat = $githubPat.Trim() }
        if ($null -eq $jenkinsUrl) { $jenkinsUrl = "" } else { $jenkinsUrl = $jenkinsUrl.Trim() }
        $jenkinsAuth = Normalize-BasicAuthValue -Value $jenkinsAuth

        $hasGithubPat = -not [string]::IsNullOrWhiteSpace($githubPat)
        $hasJenkinsUrl = -not [string]::IsNullOrWhiteSpace($jenkinsUrl)
        $hasJenkinsAuth = -not [string]::IsNullOrWhiteSpace($jenkinsAuth)

        # Light validation before saving: warn-and-skip bad values.
        if ($hasJenkinsUrl -and -not (Test-HttpUrl -Url $jenkinsUrl)) {
            Write-Warn "Jenkins URL does not look like http(s)://... - skipping URL customization."
            $hasJenkinsUrl = $false
            $jenkinsUrl = ""
        }

        if (-not $hasGithubPat -and -not $hasJenkinsUrl -and -not $hasJenkinsAuth) {
            Write-Info "No custom credentials entered; deploying opencode.json as-is."
            return $SrcPath
        }

        # Secrets are NEVER baked into JSON. Placeholders
        # (Bearer {env:GITHUB_PAT} / Basic {env:JENKINS_BASIC_AUTH}) stay as-is
        # in the template; raw values go to User env only.
        if ($hasGithubPat) {
            Save-McpSecretToUserEnv -Name 'GITHUB_PAT' -Value $githubPat -NonInteractive:$NonInteractive
        }
        $githubPat = ""
        if ($hasJenkinsAuth) {
            Save-McpSecretToUserEnv -Name 'JENKINS_BASIC_AUTH' -Value $jenkinsAuth -NonInteractive:$NonInteractive
        }
        $jenkinsAuth = ""

        $jsonDirty = $false
        if (($hasJenkinsUrl -or $hasJenkinsAuth) -and $json.mcp -and $json.mcp.servers -and $json.mcp.servers.jenkins) {
            if ($hasJenkinsUrl) {
                $json.mcp.servers.jenkins.url = $jenkinsUrl
                $jsonDirty = $true
            }
            if ($json.mcp.servers.jenkins.PSObject.Properties['disabled']) {
                $null = $json.mcp.servers.jenkins.PSObject.Properties.Remove('disabled')
                $jsonDirty = $true
            }
        }

        if (-not $jsonDirty) {
            # Only secrets were provided; JSON needs no patch (placeholders stay).
            return $SrcPath
        }

        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $staging -Encoding UTF8
        Write-Ok "Staged customized opencode.json."
        $keepStaging = $true
        return $staging
    } catch {
        Write-Warn "Skipping credential customization; deploying opencode.json as-is."
        return $SrcPath
    } finally {
        # Clear plaintext ASAP; drop the staging copy unless the caller needs it.
        $githubPat = ""
        $jenkinsAuth = ""
        if (-not $keepStaging -and $staging -and (Test-Path -Path $staging)) {
            Remove-Item -Path $staging -ErrorAction SilentlyContinue
        }
    }
}

# Prompt for optional auto-capture config and stage a customized opencode-mem.jsonc.
function Get-CustomizedOpencodeMemJson {
    param(
        [string]$SrcPath,
        [switch]$NonInteractive
    )

    if (-not (Test-Path -Path $SrcPath)) { return $SrcPath }

    $staging = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("opencode-mem.staged." + $PID + ".jsonc")
    $keepStaging = $false
    try {
        Copy-Item -Path $SrcPath -Destination $staging -Force

        try {
            $json = Get-Content -Path $staging -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warn "Could not parse opencode-mem.jsonc; deploying it unmodified."
            return $SrcPath
        }

        if ($NonInteractive) {
            Write-Info "Skipping opencode-mem auto-capture prompt (non-interactive)."
            return $SrcPath
        }

        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  OpenCode Memory Plugin (opencode-mem) - Auto-Capture Setup" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        Write-Warn "IMPORTANT: Auto-capture does NOT work with free opencode/* models."
        Write-Warn "         You need a provider with an API key (Groq, OpenAI, Anthropic, etc.)"
        Write-Warn "         or a local Ollama instance."
        Write-Host ""

        $enable = Read-Host "Enable auto-capture for memory plugin? [y/N]"
        if ($enable -notmatch '^[yY]$') {
            Write-Info "Auto-capture disabled (default). You can enable it later by editing the config."
            return $SrcPath
        }

        Write-Host ""
        Write-Host "Available providers:"
        Write-Host "  1) Groq (free tier, fast)           - openai-chat  - llama-3.3-70b-versatile - https://api.groq.com/openai/v1"
        Write-Host "  2) OpenAI                           - openai-chat  - gpt-4o-mini              - https://api.openai.com/v1"
        Write-Host "  3) Anthropic                        - anthropic    - claude-3-5-haiku-20241022 - https://api.anthropic.com/v1"
        Write-Host "  4) Ollama (local)                   - openai-chat  - llama3.1                 - http://localhost:11434/v1"
        Write-Host "  5) Custom"
        Write-Host ""

        $choice = Read-Host "Select provider [1-5]"
        switch ($choice) {
            1 { $provider = "openai-chat"; $model = "llama-3.3-70b-versatile"; $url = "https://api.groq.com/openai/v1" }
            2 { $provider = "openai-chat"; $model = "gpt-4o-mini"; $url = "https://api.openai.com/v1" }
            3 { $provider = "anthropic"; $model = "claude-3-5-haiku-20241022"; $url = "https://api.anthropic.com/v1" }
            4 { $provider = "openai-chat"; $model = "llama3.1"; $url = "http://localhost:11434/v1" }
            5 {
                $provider = Read-Host "Provider type (openai-chat/anthropic/openai-responses/minimax/orcarouter/atlas-cloud)"
                $model = Read-Host "Model name"
                $url = Read-Host "API URL"
            }
            default { $provider = ""; $model = ""; $url = "" }
        }

        if (-not [string]::IsNullOrWhiteSpace($provider) -and -not [string]::IsNullOrWhiteSpace($model) -and -not [string]::IsNullOrWhiteSpace($url)) {
            $key = Read-Host "API Key (will be saved to User environment as env var)" -AsSecureString
            if ($null -ne $key) {
                $plainKey = Convert-SecureStringToPlainText -Secure $key
                if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
                    $keyName = "OPENCODE_MEM_API_KEY"
                    [Environment]::SetEnvironmentVariable($keyName, $plainKey, 'User')
                    Set-Item -Path ("Env:" + $keyName) -Value $plainKey
                    Write-Ok "Saved $keyName to User environment."

                    if (Get-Command python3 -ErrorAction SilentlyContinue) {
                        $env:MEM_PROVIDER = $provider
                        $env:MEM_MODEL = $model
                        $env:MEM_URL = $url
                        $env:MEM_KEY = $keyName
                        python3 - $staging @"
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

data["autoCaptureEnabled"] = True
data["memoryProvider"] = provider
data["memoryModel"] = model
data["memoryApiUrl"] = url
data["memoryApiKey"] = f"env://{key_env}"

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
"@
                        Write-Ok "Configured auto-capture with ${provider}/${model}"
                    } else {
                        Write-Warn "python3 not found — auto-capture config not applied (manual edit needed)."
                    }
                } else {
                    Write-Warn "No API key provided — auto-capture not configured."
                }
                $plainKey = ""
            } else {
                Write-Warn "No API key provided — auto-capture not configured."
            }
        } else {
            Write-Warn "Incomplete provider config — auto-capture not configured."
        }

        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $staging -Encoding UTF8
        Write-Ok "Staged customized opencode-mem.jsonc."
        $keepStaging = $true
        return $staging
    } catch {
        Write-Warn "Skipping opencode-mem customization; deploying as-is."
        return $SrcPath
    } finally {
        if (-not $keepStaging -and $staging -and (Test-Path -Path $staging)) {
            Remove-Item -Path $staging -ErrorAction SilentlyContinue
        }
    }
}

# Deploy config files
function Deploy-Configs {
    param(
        [string]$TargetDir,
        [object]$GithubPat = $null,
        [string]$JenkinsUrl = "",
        [object]$JenkinsAuth = $null,
        [switch]$NonInteractive
    )

    Write-Info "Config directory: $TargetDir"

    $null = New-Item -ItemType Directory -Path $TargetDir -Force

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"

    $opencodeSrc = Join-Path -Path $ScriptDir -ChildPath "opencode.json"
    $stagedOpencodeJson = Get-CustomizedOpencodeJson -SrcPath $opencodeSrc -GithubPatParam $GithubPat -JenkinsUrlParam $JenkinsUrl -JenkinsAuthParam $JenkinsAuth -NonInteractive:$NonInteractive
    $opencodeMemSrc = Join-Path -Path $ScriptDir -ChildPath "opencode-mem.jsonc"
    $stagedOpencodeMemJson = Get-CustomizedOpencodeMemJson -SrcPath $opencodeMemSrc -NonInteractive:$NonInteractive

    foreach ($file in $ConfigFiles) {
        $src = Join-Path -Path $ScriptDir -ChildPath $file
        if ($file -eq "opencode.json" -and $stagedOpencodeJson -and (Test-Path -Path $stagedOpencodeJson)) {
            $src = $stagedOpencodeJson
        } elseif ($file -eq "opencode-mem.jsonc" -and $stagedOpencodeMemJson -and (Test-Path -Path $stagedOpencodeMemJson)) {
            $src = $stagedOpencodeMemJson
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
    if ($stagedOpencodeMemJson -and ($stagedOpencodeMemJson -ne $opencodeMemSrc) -and (Test-Path -Path $stagedOpencodeMemJson)) {
        Remove-Item -Path $stagedOpencodeMemJson -ErrorAction SilentlyContinue
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
    Deploy-Configs -TargetDir $cfgDir -GithubPat $GithubPat -JenkinsUrl $JenkinsUrl -JenkinsAuth $JenkinsAuth -NonInteractive:$NonInteractive

    # This installer session already has new secrets in $env:, so a restart
    # from here hands them to the background service directly.
    # NOTE: native-command nonzero exits do NOT throw under
    # $ErrorActionPreference='Stop' in 5.1, so check $LASTEXITCODE explicitly
    # and never abort the install here.
    # Only auto-restart when THIS run actually persisted a secret
    # ($script:SavedSecrets); inherited session env alone must not trigger it.
    if ($script:SavedSecrets) {
        Write-Info "MCP secrets are set in this session - restarting the background service so it picks them up..."
        try {
            $global:LASTEXITCODE = $null
            & opencode service restart
            if (($null -ne $LASTEXITCODE) -and ($LASTEXITCODE -eq 0)) {
                Write-Ok "opencode service restarted with the new credentials."
                Write-Info "Verifying MCP servers..."
                $global:LASTEXITCODE = $null
                & opencode mcp list
                if (($null -eq $LASTEXITCODE) -or ($LASTEXITCODE -ne 0)) {
                    Write-Warn "Could not list MCP servers - run 'opencode mcp list' manually to verify."
                }
            } else {
                Write-Warn "Could not restart opencode service automatically. Run 'opencode service restart' manually, then 'opencode mcp list' to verify."
            }
        } catch {
            Write-Warn "Could not restart opencode service automatically. Run 'opencode service restart' manually, then 'opencode mcp list' to verify."
        }
        Write-Warn "This terminal still has the old env - open a new terminal so it picks up the new User environment."
    } else {
        Write-Info "If the opencode background service is running, restart it manually: opencode service restart ; then verify with: opencode mcp list"
    }

    Write-Host ""
    Write-Ok "All done! Run 'opencode' to get started."
    Write-Host ""

    if ($SkipStar -or $NonInteractive) {
        Write-Info "Skipping star prompt."
        Write-Host ""
        return
    }
    try { $star = Read-Host "Star the repo on GitHub if you find it useful? [y/N]" } catch { $star = "" }
    if ($star -match '^[yY]') {
        $starred = $false
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if ($gh) {
            $global:LASTEXITCODE = $null
            gh auth status 2>$null
            if (($null -ne $LASTEXITCODE) -and ($LASTEXITCODE -eq 0)) {
                $global:LASTEXITCODE = $null
                gh api -X PUT "user/starred/HossamYoussof/opencode-config" --silent 2>$null
                if (($null -ne $LASTEXITCODE) -and ($LASTEXITCODE -eq 0)) {
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
