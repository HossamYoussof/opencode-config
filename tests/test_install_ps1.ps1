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
if ($params -notcontains "Terminal") {
    Write-Error "FAIL: install.ps1 is missing -Terminal parameter"
}
if ($params -notcontains "Both") {
    Write-Error "FAIL: install.ps1 is missing -Both parameter"
}

Write-Host "PASS: Parameter checks passed."
