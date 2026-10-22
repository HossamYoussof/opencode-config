# OpenCode Config

Personal [OpenCode](https://opencode.ai) configuration with MCP servers, agent presets, and a cross-platform installer.

## What's Inside

| File | Purpose |
|------|---------|
| `opencode.json` | Main V2 config — mcp.servers, plugins (no agents block, no lsp) |
| `oh-my-opencode-slim.json` | Agent model presets (opencode, openai, poe, opencode-go) |
| `opencode-mem.jsonc` | Persistent memory plugin config (auto-synced with orchestrator model) |
| `install.sh` | Installer for macOS / Linux / Windows (WSL/Git Bash) |
| `install.ps1` | Installer for native Windows (PowerShell) |
| `scripts/refresh-opencode-models.mjs` | Fetches latest free models from models.dev, updates presets + memory plugin |

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
- **jenkins** — Jenkins automation (remote, `Authorization: Basic {env:JENKINS_BASIC_AUTH}`) — ships with a placeholder URL (`https://jenkins-host/mcp-server/mcp`); set your URL + auth to enable

> Note: `xcodebuild`, `mobile`, and `ios-simulator` overlap on Apple/mobile automation. The default keeps `xcodebuild` + `mobile` enabled and `ios-simulator` disabled; enable it only if you need its simulator controls.

## Agent Presets (`oh-my-opencode-slim.json`)

The default preset is **opencode** — all free models, no API keys required.

| Preset | Orchestrator | Oracle | Use Case |
|--------|-------------|--------|----------|
| `opencode` | `opencode/muse-spark-1.3-contributor-free` (+ fallbacks) | `opencode/big-pickle` (+ fallbacks) | Free, zero-config |
| `openai` | `openai/gpt-5.6-terra` | `openai/gpt-5.6-sol` | OpenAI API users |
| `poe` | `poe/anthropic/claude-opus-4.8` | `poe/anthropic/claude-opus-4.8` | Poe subscribers |
| `opencode-go` | `opencode-go/minimax-m3` | `opencode-go/qwen3.7-max` | OpenCode Go users |

Switch presets by changing `"preset": "opencode"` in `oh-my-opencode-slim.json`.

## Quick Install

### macOS / Linux

```bash
git clone https://github.com/HossamYoussof/opencode-config.git opencode-config && cd opencode-config
./install.sh
```

Install method auto-detected in order: **curl** → **npm** → **brew** (macOS only).

Flags: `--non-interactive` (read `GITHUB_PAT` / `JENKINS_URL` / `JENKINS_BASIC_AUTH` from env, never prompt) and `--skip-mcp` (skip credentials entirely).

### Windows (PowerShell)

```powershell
git clone https://github.com/HossamYoussof/opencode-config.git opencode-config; cd opencode-config
.\install.ps1
# Non-interactive (skips credential + star prompts; honors params/env):
# .\install.ps1 -NonInteractive
# .\install.ps1 -JenkinsUrl "https://jenkins.example.com/mcp-server/mcp" -NonInteractive
# .\install.ps1 -SkipStar
```

`install.ps1` also accepts `-GithubPat` / `-JenkinsAuth` (SecureString preferred, plain string works) and falls back to `GITHUB_PAT` / `JENKINS_URL` (`JENKINS_MCP_URL`) / `JENKINS_BASIC_AUTH` (`JENKINS_AUTH`) from the process environment.

Native Windows installs via **npm only** (`npm install -g @opencode/cli`). Windows package managers (winget/scoop/choco) install the old v1 build and are not supported — use WSL + `install.sh` if you need the curl method.

The scripts will:
1. Install opencode if not already present (`install.sh`: curl → npm → brew on macOS; `install.ps1`: npm only)
2. Optionally prompt for credentials — GitHub PAT + Jenkins URL/auth (Enter to skip). Secrets are saved to your shell rc (`~/.zshrc`/`~/.bashrc`) or User env (Windows) and exported to the session; they are **never** baked into `opencode.json`, which keeps `{env:GITHUB_PAT}` / `{env:JENKINS_BASIC_AUTH}` placeholders. Only the non-secret Jenkins URL is patched into the deployed JSON (and `disabled` is removed when URL or auth is provided).
3. Copy config files to the global config directory, backing up any existing configs to `.bak.<timestamp>` first
4. Auto-restart the background service when this run persisted a secret (`install.sh`: SECRETS_SAVED_THIS_RUN; `install.ps1`: $script:SavedSecrets), otherwise print the manual restart hint.

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
cp opencode.json oh-my-opencode-slim.json opencode-mem.jsonc ~/.config/opencode/

# Windows (PowerShell)
New-Item -ItemType Directory -Force -Path "$env:APPDATA\opencode"
Copy-Item opencode.json, oh-my-opencode-slim.json, opencode-mem.jsonc "$env:APPDATA\opencode\"
```

If you need the github/jenkins MCPs, export `GITHUB_PAT` / `JENKINS_BASIC_AUTH` in your shell env (the JSON already references them via `{env:...}`), update the Jenkins `url`, remove its `"disabled": true`, then run `opencode service restart && opencode mcp list`.

## Model Refresh Script

Keep your agent presets and memory plugin model up to date with the latest free models from models.dev:

```bash
# Check what would change (dry run)
node scripts/refresh-opencode-models.mjs --dry-run

# Apply updates to both oh-my-opencode-slim.json and opencode-mem.jsonc
node scripts/refresh-opencode-models.mjs

# Deploy to ~/.config/opencode/
./install.sh --skip-mcp
```

The script:
- Fetches the latest free opencode models from models.dev
- Scores and picks the best models for each agent role (orchestrator, oracle, librarian, explorer, designer, fixer, observer)
- Validates each role's `variant` against the picked models' supported reasoning variants
- Updates `opencode-mem.jsonc` → `opencodeModel` to match the orchestrator's primary model
- Preserves JSONC comments in `opencode-mem.jsonc`
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

Add an entry under `presets` in `oh-my-opencode-slim.json` following the existing structure (orchestrator, oracle, librarian, explorer, designer, fixer agent configs).

### Persistent Memory (`opencode-mem.jsonc`)

The repo includes `opencode-mem.jsonc` for the [opencode-mem](https://www.npmjs.com/package/opencode-mem) plugin — persistent local memory using a vector database (Turso/libSQL) with ONNX embeddings.

Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `opencodeProvider` | `"opencode"` | Provider for auto-capture (uses your OpenCode auth) |
| `opencodeModel` | `"nemotron-3-ultra-free"` | Model for auto-capture (auto-synced with orchestrator) |
| `autoCaptureEnabled` | `false` | Background memory extraction from conversations |
| `storagePath` | `~/.opencode-mem/data` | Vector DB location |
| `embeddingModel` | `Xenova/nomic-embed-text-v1` | Local ONNX embedding model |
| `webServerEnabled` | `true` | Web UI at `http://localhost:4747` |

**Auto-capture** is disabled by default (free `opencode/*` models can't be used from background processes). Enable it by setting `autoCaptureEnabled: true` and configuring a provider (Groq, Ollama, OpenAI, etc.) via `memoryProvider` / `memoryApiUrl` / `memoryApiKey`.

Memory tool usage in OpenCode:
```bash
# Store a preference
> Remember I prefer TypeScript with strict mode

# Search memories
> What are my TypeScript preferences?

# List all memories
> memory list
```

Web UI: `http://localhost:4747` (when OpenCode is running)

## Requirements

- [OpenCode](https://opencode.ai) CLI installed
- [Node.js](https://nodejs.org/) + npm (for npx-based MCP servers)
- API keys configured in OpenCode for non-free presets

## License

MIT
