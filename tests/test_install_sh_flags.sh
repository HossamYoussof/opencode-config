#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Test 1: --help shows --type, --terminal, --desktop, and --both options
help_output="$("${SCRIPT_DIR}/install.sh" --help)"
for flag in "--type" "--terminal" "--desktop" "--both"; do
  if ! echo "$help_output" | grep -q -- "$flag"; then
    echo "FAIL: --help missing $flag documentation"
    exit 1
  fi
done

# Test 2: Valid flags accepted before --help
"${SCRIPT_DIR}/install.sh" --terminal --help >/dev/null
"${SCRIPT_DIR}/install.sh" --desktop --help >/dev/null
"${SCRIPT_DIR}/install.sh" --both --help >/dev/null
"${SCRIPT_DIR}/install.sh" --type desktop --help >/dev/null
"${SCRIPT_DIR}/install.sh" --type=both --help >/dev/null

# Test 3: --type missing value fails
if "${SCRIPT_DIR}/install.sh" --type >/dev/null 2>&1; then
  echo "FAIL: --type without argument should fail"
  exit 1
fi

# Test 4: Sourcing install.sh for prompt_install_type normalization & defaults
source "${SCRIPT_DIR}/install.sh" --source-only 2>/dev/null || true

# 4a: OPENCODE_INSTALL_TYPE normalization
INSTALL_TYPE="desktop"
prompt_install_type
[[ "$INSTALL_TYPE" == "desktop" ]] || { echo "FAIL: Expected desktop"; exit 1; }

INSTALL_TYPE="cli"
prompt_install_type
[[ "$INSTALL_TYPE" == "terminal" ]] || { echo "FAIL: Expected terminal for cli"; exit 1; }

INSTALL_TYPE="both"
prompt_install_type
[[ "$INSTALL_TYPE" == "both" ]] || { echo "FAIL: Expected both"; exit 1; }

INSTALL_TYPE="gui"
prompt_install_type
[[ "$INSTALL_TYPE" == "desktop" ]] || { echo "FAIL: Expected desktop for gui"; exit 1; }

INSTALL_TYPE="all"
prompt_install_type
[[ "$INSTALL_TYPE" == "both" ]] || { echo "FAIL: Expected both for all"; exit 1; }

INSTALL_TYPE="invalid_value"
prompt_install_type
[[ "$INSTALL_TYPE" == "terminal" ]] || { echo "FAIL: Expected terminal for invalid"; exit 1; }

# 4b: Non-interactive mode defaults to terminal
INSTALL_TYPE=""
NON_INTERACTIVE=1
prompt_install_type
[[ "$INSTALL_TYPE" == "terminal" ]] || { echo "FAIL: Expected non-interactive terminal default"; exit 1; }

# 4c: Non-tty stdin defaults to terminal
INSTALL_TYPE=""
NON_INTERACTIVE=0
prompt_install_type </dev/null
[[ "$INSTALL_TYPE" == "terminal" ]] || { echo "FAIL: Expected non-tty terminal default"; exit 1; }

# Test 5: Interactive prompt in PTY with simulated user input
if command -v python3 &>/dev/null; then
  test_pty_prompt() {
    local input="$1"
    local expected="$2"
    local res
    res="$(python3 -c "
import pty, os, subprocess
master, slave = pty.openpty()
p = subprocess.Popen(
    ['bash', '-c', 'source \"${SCRIPT_DIR}/install.sh\" --source-only 2>/dev/null; INSTALL_TYPE=\"\"; NON_INTERACTIVE=0; prompt_install_type >/dev/null 2>&1; echo RESULT:\$INSTALL_TYPE'],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True
)
os.close(slave)
os.write(master, b'''$input\n''')
out = b''
while True:
    try:
        data = os.read(master, 1024)
        if not data: break
        out += data
    except OSError:
        break
os.close(master)
p.wait()
for line in out.decode().splitlines():
    if line.startswith('RESULT:'):
        print(line.split(':', 1)[1])
")"
    if [[ "$res" != "$expected" ]]; then
      echo "FAIL: For input '$input', expected '$expected', got '$res'"
      exit 1
    fi
  }

  test_pty_prompt "2" "desktop"
  test_pty_prompt "3" "both"
  test_pty_prompt "1" "terminal"
  test_pty_prompt "" "terminal"
fi

echo "PASS: Flag parsing and prompt tests passed."
