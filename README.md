# OpenCode Config

Personal [OpenCode](https://opencode.ai) configuration with MCP servers, agent presets, and a cross-platform installer.

## What's Inside

| File | Purpose |
|------|---------|
| `opencode.json` | Main config — MCP servers, plugins, agent toggles, LSP |
| `oh-my-opencode-slim.json` | Agent model presets (zen-free, openai, poe, opencode-go) |
| `install.sh` | Installer for macOS / Linux / Windows (WSL/Git Bash) |
| `install.ps1` | Installer for native Windows (PowerShell) |

## MCP Servers

Enabled by default:

- **gitnexus** — Code knowledge graph (local, npx)
- **xcodebuild** — Apple platform build/test/debug (local, npx)
- **mobile** — Mobile device automation (local, npx)
- **firebase** — Firebase CLI integration (local, npx)
- **figma** — Figma design handoff (remote)
- **sentry** — Error tracking (remote)
- **github** — GitHub Copilot MCP (remote, requires key)

Disabled (enable as needed):

- **linear** — Linear project management
- **clickup** — ClickUp project management
- **luciq** — Instabug integration
- **ios-simulator** — iOS simulator control (superseded by xcodebuild)

## Agent Presets (`oh-my-opencode-slim.json`)

The default preset is **zen-free** — all free models, no API keys required.

| Preset | Orchestrator | Oracle | Use Case |
|--------|-------------|--------|----------|
| `zen-free` | `opencode/big-pickle` | `opencode/nemotron-3-ultra-free` | Free, zero-config |
| `openai` | `openai/gpt-5.5` | `openai/gpt-5.5` | OpenAI API users |
| `poe` | `poe/anthropic/claude-opus-4.8` | `poe/anthropic/claude-opus-4.8` | Poe subscribers |
| `opencode-go` | `opencode-go/glm-5.1` | `opencode-go/deepseek-v4-pro` | OpenCode Go users |

Switch presets by changing `"preset": "zen-free"` in `oh-my-opencode-slim.json`.

## Quick Install

### macOS / Linux

```bash
git clone <repo-url> opencode-config && cd opencode-config
./install.sh
```

### Windows (PowerShell)

```powershell
git clone <repo-url> opencode-config; cd opencode-config
.\install.ps1
```

The scripts will:
1. Install opencode if not already present (via curl, npm, brew, winget, scoop, or choco)
2. Copy config files to the global config directory
3. Back up any existing configs before overwriting

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

## Customization

### Add an MCP server

Edit `opencode.json` → `mcp` section:

```json
"my-server": {
  "type": "local",
  "command": ["npx", "-y", "my-mcp-server"],
  "enabled": true
}
```

### Switch model preset

Edit `oh-my-opencode-slim.json` → change the `preset` field:

```json
"preset": "openai"
```

### Add a new preset

Add an entry under `presets` in `oh-my-opencode-slim.json` following the existing structure (orchestrator, oracle, librarian, explorer, designer, fixer agent configs).

## Requirements

- [OpenCode](https://opencode.ai) CLI installed
- [Node.js](https://nodejs.org/) + npm (for npx-based MCP servers)
- API keys configured in OpenCode for non-free presets

## License

MIT
