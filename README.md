# OpenCode Config

Personal [OpenCode](https://opencode.ai) configuration with MCP servers, agent presets, and a cross-platform installer.

## What's Inside

| File | Purpose |
|------|---------|
| `opencode.json` | Main V2 config — provider configurations (SovereignEG), mcp.servers, plugins (no agents block, no lsp) |
| `oh-my-opencode-slim.json` | Agent model presets (opencode, openai, poe, opencode-go, nvidia, sovereigneg) |
| `install.sh` | Installer for macOS / Linux / Windows (WSL/Git Bash) |
| `install.ps1` | Installer for native Windows (PowerShell) |
| `scripts/refresh-opencode/refresh-opencode-models.mjs` | Fetches latest free models from models.dev, updates presets + memory plugin |
| `scripts/refresh-nvidia/refresh-nvidia-models.mjs` | Fetches NVIDIA NIM models, tests them live, updates nvidia preset + memory plugin |

`opencode.json` uses the native V2 shape: `mcp.servers` (not bare `mcp`), `disabled: true/false` (not `enabled`), and `plugins` (plural). There is no `agent`/`agents` block — explore/general agents run at defaults (enabled) — and no `lsp` key.

## MCP Servers

Enabled by default:

- **gitnexus** — Code knowledge graph (local, npx)
- **xcodebuild** — Apple platform build/test/debug (local, npx)
- **mobile** — Mobile device automation (local, npx)
- **firebase** — Firebase CLI integration (local, npx)
- **figma** — Figma design handoff (remote, `oauth: false`) — requires the Figma Desktop MCP server running on `http://127.0.0.1:3845/mcp`
- **sentry** — Error tracking (remote) — sign in via `/mcps` after install
- **github** — GitHub Copilot MCP (remote, `oauth: false`, `Authorization: Bearer {env:GITHUB_PAT}`) — requires the `GITHUB_PAT` env var, or switch it to OAuth via `/mcps`

Disabled by default (enable as needed by removing `"disabled": true`):

- **ios-simulator** — iOS simulator control (local, npx) — overlaps with **xcodebuild** and **mobile**; kept disabled to avoid redundant tools
- **linear** — Linear project management (remote)
- **clickup** — ClickUp project management (remote)
- **luciq** — Instabug integration (remote)

> Note: `xcodebuild`, `mobile`, and `ios-simulator` overlap on Apple/mobile automation. The default keeps `xcodebuild` + `mobile` enabled and `ios-simulator` disabled; enable it only if you need its simulator controls.

## Agent Presets (`oh-my-opencode-slim.json`)

The default preset is **opencode** — all free models, no API keys required.

| Preset | Orchestrator | Oracle | Use Case |
|--------|-------------|--------|----------|
| `opencode` | `opencode/muse-spark-1.3-contributor-free` (+ fallbacks) | `opencode/big-pickle` (+ fallbacks) | Free, zero-config |
| `openai` | `openai/gpt-5.6-terra` | `openai/gpt-5.6-sol` | OpenAI API users |
| `poe` | `poe/anthropic/claude-opus-4.8` | `poe/anthropic/claude-opus-4.8` | Poe subscribers |
| `opencode-go` | `opencode-go/minimax-m3` | `opencode-go/qwen3.7-max` | OpenCode Go users |
| `nvidia` | `nvidia/nemotron-3.5-super-vl-120b-a12b` (+ Lightning, Nano Omni fallbacks) | `nvidia/nemotron-3.5-super-vl-120b-a12b` (+ Lightning fallbacks) | NVIDIA NIM API users — reasoning/VL capable |
| `sovereigneg` | `sovereigneg/claude-opus-4.8` (+ Qwen3.8 Max, Qwen3.8-27B-FP8, Sonnet 4.6 fallbacks) | `sovereigneg/claude-opus-4.8` (+ DeepSeek V3.1 Terminus, Beam 1.0, Qwen4 Max fallbacks) | [SovereignEG](https://sovereigneg.com/docs) users — Egypt-hosted & frontier models billed in EGP |

Switch presets by changing `"preset": "opencode"` in `oh-my-opencode-slim.json`.

## Quick Install

The installers support **Terminal (CLI)**, **Desktop (GUI App)**, or **Both**:
- **Terminal (CLI)**: Installs the `opencode` command-line tool.
- **Desktop (GUI App)**: Downloads the official OS-specific installer (`.dmg` on macOS, `.exe` on Windows, `.AppImage` on Linux) to `~/Downloads` and launches it.
- **Both**: Installs both the CLI and Desktop application.

Regardless of the selected type, configuration files (`opencode.json` and `oh-my-opencode-slim.json`) are deployed to the global config directory so both CLI and Desktop share your presets and MCP servers.

In interactive mode, the installer prompts you to choose your installation type. In non-interactive mode or automated scripts, it defaults to **Terminal** unless overridden by CLI flags or the `OPENCODE_INSTALL_TYPE` environment variable (`terminal`, `desktop`, or `both`).

### macOS / Linux

```bash
git clone https://github.com/HossamYoussof/opencode-config.git opencode-config && cd opencode-config
./install.sh

# Choose target via flags:
# ./install.sh --desktop         # Desktop GUI app only
# ./install.sh --terminal        # Terminal CLI only
# ./install.sh --both            # Both Desktop and Terminal
# ./install.sh --type desktop    # Alternative using --type <terminal|desktop|both>
```

**Options & Flags:**
- `--type <terminal|desktop|both>`: Select installation type.
- `--desktop`: Install OpenCode Desktop (GUI App) only.
- `--terminal`: Install OpenCode Terminal (CLI) only.
- `--both`: Install both Terminal and Desktop.
- `--non-interactive`: Read `GITHUB_PAT` from env, never prompt (defaults to Terminal if type unspecified).
- `--skip-mcp`: Skip MCP credential prompts entirely.
- `OPENCODE_INSTALL_TYPE`: Set via environment variable (`export OPENCODE_INSTALL_TYPE=desktop`).

**How it works:**
- **Terminal**: Install method auto-detected in order: **curl** → **npm** → **brew** (macOS only).
- **Desktop**: Fetches the latest release metadata from the OpenCode API, downloads the installer to `~/Downloads` (`.dmg` for macOS, `.AppImage` for Linux, `.exe` for Windows under WSL/Git Bash), and launches it (on macOS, mounts DMG, copies `OpenCode.app` to `/Applications`, and opens it).

### Windows (PowerShell)

```powershell
git clone https://github.com/HossamYoussof/opencode-config.git opencode-config; cd opencode-config
.\install.ps1

# Choose target via parameters:
# .\install.ps1 -Desktop         # Desktop GUI app only
# .\install.ps1 -Terminal        # Terminal CLI only
# .\install.ps1 -Both            # Both Desktop and Terminal
# .\install.ps1 -Type Desktop    # Alternative using -Type <Terminal|Desktop|Both>

# Non-interactive (skips credential + star prompts; honors params/env):
# .\install.ps1 -NonInteractive
# .\install.ps1 -Desktop -NonInteractive
# .\install.ps1 -SkipStar
```

**Parameters & Environment:**
- `-Type <Terminal|Desktop|Both>`: Select installation type.
- `-Desktop`: Install OpenCode Desktop (GUI App) only.
- `-Terminal`: Install OpenCode Terminal (CLI) only.
- `-Both`: Install both Terminal and Desktop.
- `-NonInteractive`: Skips credential and star prompts (defaults to Terminal if type unspecified).
- `$env:OPENCODE_INSTALL_TYPE`: Set via environment variable (`$env:OPENCODE_INSTALL_TYPE = "Desktop"`).
- `-GithubPat`: Optional credential (SecureString preferred, plain string works); falls back to `GITHUB_PAT` from the process environment.

**How it works:**
- **Terminal**: Native Windows CLI installs via **npm only** (`npm install -g @opencode/cli`). Windows package managers (winget/scoop/choco) install the old v1 build and are not supported — use WSL + `install.sh` if you need the curl method.
- **Desktop**: Fetches the latest release metadata from the OpenCode API, downloads the official Windows installer (`opencode-desktop-win-x64.exe` or `arm64`) to `$env:USERPROFILE\Downloads`, and launches the setup wizard.

### What the Installers Do

The scripts will:
1. **Resolve Installation Target**: Prompt for or resolve installation type (**Terminal**, **Desktop**, or **Both**).
   - If Terminal is selected: install CLI if not already present.
   - If Desktop is selected: download the official installer to `~/Downloads` and launch it.
2. **Configure Credentials (Optional)**: Prompt for GitHub PAT (Enter to skip). Secrets are saved to your shell rc (`~/.zshrc`/`~/.bashrc`) or User env (Windows) and exported to the session; they are **never** baked into `opencode.json`, which keeps `{env:GITHUB_PAT}` placeholders.
3. **Deploy Configs**: Copy `opencode.json` and `oh-my-opencode-slim.json` to the global config directory (for all install types), backing up any existing configs to `.bak.<timestamp>` first.
4. **Restart Background Service**: Auto-restart the background service when this run persisted a secret (`install.sh`: SECRETS_SAVED_THIS_RUN; `install.ps1`: $script:SavedSecrets), otherwise print the manual restart hint.

Post-install, reload your shell and verify:

```bash
opencode service restart && opencode mcp list
```

Troubleshooting: `400` / badly-formatted errors from the github MCP usually mean `GITHUB_PAT` is unset or empty — export it (`export GITHUB_PAT="..."` / `source ~/.zshrc`), restart the service, and re-run `opencode mcp list`. Alternatively switch github to OAuth via `/mcps`.

### Config Locations

| OS | Path |
|----|------|
| macOS / Linux | `~/.config/opencode/` |
| Windows | `%APPDATA%\opencode\` |

## Manual Install

Copy the config files directly:

```bash
# macOS / Linux
mkdir -p ~/.config/opencode
cp opencode.json oh-my-opencode-slim.json ~/.config/opencode/

# Windows (PowerShell)
New-Item -ItemType Directory -Force -Path "$env:APPDATA\opencode"
Copy-Item opencode.json, oh-my-opencode-slim.json "$env:APPDATA\opencode\"
```

If you need the github MCP, export `GITHUB_PAT` in your shell env (the JSON already references it via `{env:GITHUB_PAT}`), then run `opencode service restart && opencode mcp list`.

## Model Refresh Script

Keep your agent presets and memory plugin model up to date with the latest free models from models.dev:

```bash
# Check what would change (dry run)
node scripts/refresh-opencode/refresh-opencode-models.mjs --dry-run

# Apply updates to oh-my-opencode-slim.json
node scripts/refresh-opencode/refresh-opencode-models.mjs

# Deploy to ~/.config/opencode/
./install.sh --skip-mcp
```

The script:
- Fetches the latest free opencode models from models.dev
- Scores and picks the best models for each agent role (orchestrator, oracle, explorer, designer, fixer)
- Validates each role's `variant` against the picked models' supported reasoning variants
- Runs in CI with `--check` (exits 1 if changes would be made)

## NVIDIA Model Refresh Script

Keep your NVIDIA `nvidia` agent preset up to date with the latest NVIDIA NIM models:

```bash
# Check what would change (dry run)
node scripts/refresh-nvidia/refresh-nvidia-models.mjs --dry-run

# Apply updates to oh-my-opencode-slim.json
NVIDIA_API_KEY="your-key" node scripts/refresh-nvidia/refresh-nvidia-models.mjs

# Deploy to ~/.config/opencode/
./install.sh --skip-mcp
```

The script:
- Fetches available models from the NVIDIA NIM catalog (`https://integrate.api.nvidia.com/v1/models`)
- Requires `NVIDIA_API_KEY` for catalog authentication
- Filters to 8 known-working models with hardcoded metadata from prior live testing
- Live-tests each candidate via a chat completion before selection (`--test-live`)
- Picks top models per agent role (orchestrator, oracle, explorer, designer, fixer)
- Handles `nvidia/`, `poolside/`, and `meta/` org prefixes correctly
- Runs in CI with `--check` (exits 1 if changes would be made)


## Customization

### Add an MCP server

Edit `opencode.json` → `mcp.servers`. Servers are enabled unless they set `"disabled": true` (there is no `enabled` flag in V2).

Local example:

```json
"mcp": {
  "servers": {
    "my-server": {
      "type": "local",
      "command": ["npx", "-y", "my-mcp-server"]
    }
  }
}
```

Remote example with env-based auth header:

```json
"mcp": {
  "servers": {
    "my-remote": {
      "type": "remote",
      "url": "https://example.com/mcp",
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:MY_API_TOKEN}"
      }
    }
  }
}
```

To keep a server installed but off by default, add `"disabled": true`.

### Switch model preset

Edit `oh-my-opencode-slim.json` → change the `preset` field:

```json
"preset": "openai"
```

### Add a new preset

Add an entry under `presets` in `oh-my-opencode-slim.json` following the existing structure (orchestrator, oracle, explorer, designer, fixer agent configs).

### Persistent Memory (manual config)

OpenCode memory is provided by the [opencode-mem](https://www.npmjs.com/package/opencode-mem) plugin — persistent local memory using a vector database (Turso/libSQL) with ONNX embeddings. This repo no longer ships an `opencode-mem.jsonc` config file, so you set it up manually:

1. Enable the plugin in `opencode.json` → `plugins` (add it if not present):
   ```json
   "plugins": ["@tarquinen/opencode-dcp@latest", "oh-my-opencode-slim@latest", "opencode-mem@latest"]
   ```
2. Create `~/.config/opencode/opencode-mem.jsonc` with your settings. Minimum example:
   ```jsonc
   {
     // Storage location for vector database
     "storagePath": "~/.opencode-mem/data",

     // OpenCode provider (recommended — uses your existing OpenCode auth)
     "opencodeProvider": "opencode",
     "opencodeModel": "inherit",

     // Auto-capture is disabled by default.
     "autoCaptureEnabled": false,

     // Enable web UI for managing memories (http://localhost:4747)
     "webServerEnabled": true,
     "webServerPort": 4747,
     "webServerHost": "127.0.0.1"
   }
   ```
3. Restart the service: `opencode service restart && opencode mcp list`, then open the Web UI at `http://localhost:4747`.

Auto-capture (optional):
- Free `opencode/*` models can't be used from background processes, so auto-capture is disabled by default.
- To enable it, set `autoCaptureEnabled: true` and configure a provider via `memoryProvider` / `memoryModel` / `memoryApiUrl` / `memoryApiKey` (OpenAI-compatible, Anthropic, MiniMax, OrcaRouter, Atlas Cloud, or Groq via `openai-chat`).
- Store API keys as env vars (e.g. `env://GROQ_API_KEY`) rather than plaintext in the file.

## Requirements

- [OpenCode](https://opencode.ai) (CLI or Desktop) installed
- [Node.js](https://nodejs.org/) + npm (for npx-based MCP servers)
- API keys configured in OpenCode for non-free presets

## License

MIT
