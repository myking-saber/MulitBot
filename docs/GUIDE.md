# MulitBot User Guide

## What is MulitBot?

MulitBot is a multi-agent collaboration framework built on [Claude Code](https://claude.ai/claude-code). It lets you manage software projects from your phone — describe what you want, and an AI boss automatically assembles a team of specialists (product manager, architect, designer, tester, etc.) who discuss, plan, and build it for you.

**Think of it as**: You're the client. You text the boss. The boss hires a team and manages the project. You watch from your phone and get the result.

## Why MulitBot?

| Problem | MulitBot Solution |
|---------|-------------------|
| One AI can't do everything well | Multiple specialized AI roles with distinct personalities and expertise |
| AI jumps to code without planning | Enforced discussion workflow: Requirements → Design → Technical Plan → Decision → Code |
| No project visibility | Real-time phone UI with channel-based communication |
| Context gets lost in long sessions | Three-layer memory: individual + team + cross-project experience |
| Wasted resources | Lazy loading: only Boss starts initially, team members spawn on demand |

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    Your Phone                        │
│  ┌─────────────────────────────────────────────┐    │
│  │         MulitBot Web UI                      │    │
│  │  #general  #proj-snake  #proj-api            │    │
│  │  ┌─────────────────────────────────────┐    │    │
│  │  │ [boss] Team assembled! Discussion   │    │    │
│  │  │ in #proj-snake...                   │    │    │
│  │  │ [boss] Project complete! ✅         │    │    │
│  │  └─────────────────────────────────────┘    │    │
│  │  ┌─────────────────────────────┐            │    │
│  │  │ Tell the boss what you need │  [Send]    │    │
│  │  └─────────────────────────────┘            │    │
│  └─────────────────────────────────────────────┘    │
└──────────────────────┬──────────────────────────────┘
                       │ WebSocket
┌──────────────────────▼──────────────────────────────┐
│                  Hub Server                          │
│  HTTP API + WebSocket + JSONL Storage + Logging      │
└──┬──────────┬──────────┬──────────┬─────────────────┘
   │          │          │          │
┌──▼──┐  ┌───▼──┐  ┌───▼───┐  ┌──▼────┐
│Boss │  │Lead  │  │Product│  │Archit.│  ← Claude Code instances
│(AI) │  │(AI)  │  │(AI)   │  │(AI)   │    in tmux windows
└─────┘  └──────┘  └───────┘  └───────┘
   │          │          │          │
   └──────────┴──────────┴──────────┘
              Monitor daemon
         (auto-wake + crash recovery)
```

## Key Features

### For Clients (You)
- **Phone-first**: Send requirements and monitor progress from your phone browser
- **Real-time notifications**: Sound, vibration, browser push when your attention is needed
- **Project isolation**: Each project gets its own channel (#proj-xxx)
- **Stop anytime**: One-tap project interruption button
- **Export logs**: Download full conversation as Markdown for records

### For the AI Team
- **Enforced workflow**: No skipping discussion — Requirements → Design → Tech → Decision → Code
- **Role reuse**: Roles accumulate experience across projects and get stronger over time
- **Lazy loading**: Only start Claude instances when actually needed
- **Crash recovery**: Monitor daemon auto-detects and restarts crashed bots
- **Anti-loop**: 3-round limit between any two roles, mandatory Lead escalation

### For Developers
- **Self-hosted**: All data stays on your machine, no third-party services
- **Structured logging**: JSON logs for Hub, Monitor, MCP plugins, and system events
- **i18n**: Full multi-language support (zh-CN, en, ja) for scripts, Web UI, and AI instructions
- **MIT License**: Use it however you want

## Quick Start

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Bun | 1.0+ | [bun.sh](https://bun.sh) |
| Claude Code | 2.0+ | [claude.ai/claude-code](https://claude.ai/claude-code) |
| tmux | 3.0+ | `apt install tmux` |
| jq | 1.6+ | `apt install jq` |

You also need an active Claude subscription (Claude Max or API key).

### Install

```bash
git clone https://github.com/anthropics/MulitBot.git
cd MulitBot
cd plugins/multibot-hub && bun install && cd ../..
```

### Configure Language (Optional)

Edit `team.json`:
```json
{
  "lang": "en"
}
```

Leave `"lang": ""` to auto-detect from system locale.

### Start

```bash
bash scripts/start.sh
```

This starts only 3 processes:
- **Hub** — Message server (tmux: hub)
- **Boss** — AI manager (tmux: boss)
- **Monitor** — Auto-wake + crash recovery daemon (tmux: monitor)

Open `http://<your-ip>:7800` on your phone.

### Your First Project

1. Type in the phone UI: `@boss Build me a todo list CLI app`
2. Watch Boss assemble a team (Lead + Product + Architect)
3. Switch to #proj-todo to watch the team discuss
4. Get notified when it's done
5. Find the code in `projects/todo/code/`

### Stop

```bash
bash scripts/stop.sh
```

## Remote Access

### Same WiFi
Just open `http://<lan-ip>:7800` on your phone.

### With Authentication
```bash
HUB_SECRET=your-secret bash scripts/start.sh
# Phone: http://<lan-ip>:7800?secret=your-secret
```

### Public Internet (cloudflared)
```bash
HUB_SECRET=your-secret HUB_TUNNEL=cloudflared bash scripts/start.sh
```

## Project Structure

```
MulitBot/
├── scripts/           # All operational scripts
│   ├── start.sh       # Start system (Hub + Boss + Monitor)
│   ├── stop.sh        # Stop everything
│   ├── add-member.sh  # Add team member on demand
│   ├── recruit.sh     # Generate/reuse role definitions
│   ├── list-roles.sh  # List reusable roles
│   ├── monitor.sh     # Auto-wake + crash recovery
│   ├── export-log.sh  # Export conversations to Markdown
│   ├── i18n.sh        # Script internationalization
│   └── ...
├── plugins/multibot-hub/  # Self-hosted message system
│   ├── hub.ts         # HTTP + WebSocket + Web UI server
│   ├── server.ts      # MCP plugin (Claude Code ↔ Hub)
│   ├── storage.ts     # JSONL storage layer
│   └── ui/            # Mobile Web UI
├── bots/              # Bot working directories
│   ├── boss/          # Boss AI (always running)
│   ├── lead/          # Lead coordinator
│   ├── architect/     # Technical architect
│   └── ...            # Other roles
├── roles/             # Reusable role templates + experience
├── projects/          # Project workspaces + code output
├── data/              # Runtime data + logs
└── team.json          # Current team configuration
```

## How the Memory System Works

```
Project 1                    Project 2
┌────────────┐              ┌────────────┐
│ architect   │──────────────│ architect   │  ← Same role, reused
│ memory: v1  │   experience │ memory: v2  │
│             │──────────>   │ + v1 exp    │  ← Experience carried over
└────────────┘    file       └────────────┘

workspace/team-knowledge/    workspace/team-knowledge/
(shared within project)      (separate per project)
```

- **Individual**: Claude Code auto-memory per bot directory
- **Team**: Shared files in `workspace/team-knowledge/`
- **Cross-project**: `roles/<id>.experience.md` — saved before context compression, loaded on role reuse

## Contributing

PRs welcome! Key areas:
- Additional language packs (`roles/i18n/`, `bots/boss/i18n/`, `plugins/multibot-hub/ui/lang.js`)
- New pre-built role templates
- Web UI improvements
- Documentation

## License

MIT — see [LICENSE](../LICENSE)
