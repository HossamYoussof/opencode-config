#!/usr/bin/env python3
"""
Static analysis and contract test for install.ps1.
Validates parameter declarations, functions, asset resolution, download logic,
and execution flow in environments where PowerShell is not available.
"""
import os
import re
import sys

def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ps1_path = os.path.join(repo_root, "install.ps1")
    ps1_test_path = os.path.join(repo_root, "tests", "test_install_ps1.ps1")

    # 1. Verify tests/test_install_ps1.ps1 exists and contains parameter assertions
    if not os.path.isfile(ps1_test_path):
        print("FAIL: tests/test_install_ps1.ps1 does not exist")
        sys.exit(1)

    with open(ps1_test_path, "r", encoding="utf-8") as f:
        test_ps1_content = f.read()

    for p in ["Type", "Desktop", "Terminal", "Both"]:
        if p not in test_ps1_content:
            print(f"FAIL: tests/test_install_ps1.ps1 does not test parameter '{p}'")
            sys.exit(1)

    # 2. Verify install.ps1 exists
    if not os.path.isfile(ps1_path):
        print(f"FAIL: {ps1_path} not found")
        sys.exit(1)

    with open(ps1_path, "r", encoding="utf-8") as f:
        content = f.read()

    # 3. Parameter Block Validation
    param_match = re.search(r"param\s*\((.*?)\)\s*(?:\r?\n)+\$ErrorActionPreference", content, re.DOTALL | re.IGNORECASE)
    if not param_match:
        print("FAIL: top-level param(...) block not found in install.ps1")
        sys.exit(1)

    param_block = param_match.group(1)

    required_params = [
        (r'\[ValidateSet\("Terminal",\s*"Desktop",\s*"Both"\)\]\s*\[string\]\s*\$Type', "Type with ValidateSet"),
        (r'\[switch\]\s*\$Terminal', "switch $Terminal"),
        (r'\[switch\]\s*\$Desktop', "switch $Desktop"),
        (r'\[switch\]\s*\$Both', "switch $Both"),
        (r'\$GithubPat', "$GithubPat"),
        (r'\[switch\]\s*\$NonInteractive', "switch $NonInteractive"),
        (r'\[switch\]\s*\$SkipStar', "switch $SkipStar"),
    ]

    for pattern, desc in required_params:
        if not re.search(pattern, param_block, re.IGNORECASE):
            print(f"FAIL: install.ps1 is missing {desc} parameter in param() block")
            sys.exit(1)

    # 4. Function Definitions
    functions = ["Get-DesktopDownloadInfo", "Download-And-Install-Desktop", "Get-InstallType"]
    for fn in functions:
        if not re.search(rf"function\s+{re.escape(fn)}\b", content, re.IGNORECASE):
            print(f"FAIL: install.ps1 is missing function {fn}")
            sys.exit(1)

    # 5. Logic validation for Get-DesktopDownloadInfo
    info_match = re.search(r"function\s+Get-DesktopDownloadInfo\s*\{(.*?)\n\}", content, re.DOTALL | re.IGNORECASE)
    if not info_match:
        print("FAIL: Could not extract Get-DesktopDownloadInfo function body")
        sys.exit(1)
    info_body = info_match.group(1)

    if "PROCESSOR_ARCHITECTURE" not in info_body or "ARM64" not in info_body:
        print("FAIL: Get-DesktopDownloadInfo does not check PROCESSOR_ARCHITECTURE for ARM64")
        sys.exit(1)

    if "opencode-desktop-win-arm64.exe" not in info_body or "opencode-desktop-win-x64.exe" not in info_body:
        print("FAIL: Get-DesktopDownloadInfo does not define correct Windows executable filenames")
        sys.exit(1)

    if "https://opencode.ai/update/api/latest/desktop" not in info_body:
        print("FAIL: Get-DesktopDownloadInfo does not query the official desktop update API")
        sys.exit(1)

    if "https://opencode.ai/files/bin/" not in info_body or "2.4.1" not in info_body:
        print("FAIL: Get-DesktopDownloadInfo missing fallback URL")
        sys.exit(1)

    # 6. Logic validation for Download-And-Install-Desktop
    dl_match = re.search(r"function\s+Download-And-Install-Desktop\s*\{(.*?)\n\}", content, re.DOTALL | re.IGNORECASE)
    if not dl_match:
        print("FAIL: Could not extract Download-And-Install-Desktop function body")
        sys.exit(1)
    dl_body = dl_match.group(1)

    if "Get-DesktopDownloadInfo" not in dl_body:
        print("FAIL: Download-And-Install-Desktop does not call Get-DesktopDownloadInfo")
        sys.exit(1)

    if "USERPROFILE" not in dl_body or "Downloads" not in dl_body:
        print("FAIL: Download-And-Install-Desktop does not target Downloads folder")
        sys.exit(1)

    if "Invoke-WebRequest" not in dl_body:
        print("FAIL: Download-And-Install-Desktop does not invoke Invoke-WebRequest")
        sys.exit(1)

    if "Start-Process" not in dl_body:
        print("FAIL: Download-And-Install-Desktop does not call Start-Process")
        sys.exit(1)

    # 7. Logic validation for Get-InstallType
    type_match = re.search(r"function\s+Get-InstallType\s*\{(.*?)\n\}", content, re.DOTALL | re.IGNORECASE)
    if not type_match:
        print("FAIL: Could not extract Get-InstallType function body")
        sys.exit(1)
    type_body = type_match.group(1)

    if "$Both" not in type_body or "$Desktop" not in type_body or "$Terminal" not in type_body:
        print("FAIL: Get-InstallType does not check switch parameters")
        sys.exit(1)

    if "OPENCODE_INSTALL_TYPE" not in type_body:
        print("FAIL: Get-InstallType does not check OPENCODE_INSTALL_TYPE env variable")
        sys.exit(1)

    if "$NonInteractive" not in type_body:
        print("FAIL: Get-InstallType does not handle $NonInteractive")
        sys.exit(1)

    if "Read-Host" not in type_body:
        print("FAIL: Get-InstallType does not prompt interactively via Read-Host")
        sys.exit(1)

    # 8. Main execution flow validation
    main_match = re.search(r"function\s+Main\s*\{(.*?)\n\}", content, re.DOTALL | re.IGNORECASE)
    if not main_match:
        print("FAIL: Could not extract Main function body")
        sys.exit(1)
    main_body = main_match.group(1)

    if "Get-InstallType" not in main_body:
        print("FAIL: Main does not call Get-InstallType")
        sys.exit(1)

    if "Download-And-Install-Desktop" not in main_body:
        print("FAIL: Main does not conditionally invoke Download-And-Install-Desktop")
        sys.exit(1)

    if "Install-Opencode" not in main_body:
        print("FAIL: Main does not invoke Install-Opencode")
        sys.exit(1)

    if "Deploy-Configs" not in main_body:
        print("FAIL: Main does not invoke Deploy-Configs")
        sys.exit(1)

    print("PASS: All install.ps1 syntax, parameter, and function structure checks passed.")

if __name__ == "__main__":
    main()
