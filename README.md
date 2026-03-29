# MulitBot — Multi-Agent Collaboration Framework for Claude Code

A framework that turns multiple Claude Code instances into a self-organizing team. You describe what you want from your phone, and an AI boss automatically assembles a team (product manager, architect, designer, etc.), runs discussions, and delivers results.

**[English Guide](./docs/GUIDE.md)** | **[中文指南](./docs/GUIDE.zh-CN.md)** | **[Developer Docs](./CLAUDE.md)**

## How It Works

```
You (Phone) ──→ #general channel ──→ Boss (Claude Code)
                                        │
                            ┌───────────┼───────────┐
                            ▼           ▼           ▼
                         Lead      Architect     Artist    ← Auto-assembled team
                            │           │           │
                            └───────────┼───────────┘
                                        ▼
                              #proj-xxx channel
                            (team discusses here)
                                        │
                                        ▼
                              Code + Decisions + Docs
```

1. **You text the boss** from your phone: *"Build me a snake game"*
2. **Boss analyzes** the request and assembles the right team (at least Lead + Product + Architect)
3. **Team discusses** requirements → design → technical plan → decision (enforced workflow, no skipping)
4. **Team executes** — writes code, tests, reviews
5. **Boss reports back** to you with the result
6. **You monitor everything** in real-time from your phone

## Quick Start

### Prerequisites

- [Bun](https://bun.sh) (for Hub server)
- [Claude Code CLI](https://claude.ai/claude-code) (with active subscription)
- tmux, jq

### Install & Run

```bash
git clone https://github.com/yourname/MulitBot.git
cd MulitBot

# Install Hub dependencies
cd plugins/multibot-hub && bun install && cd ../..

# Start (only Hub + Boss + Monitor — team members start on demand)
bash scripts/start.sh
```

Open `http://<your-ip>:7800` on your phone and start chatting with `@boss`.

### Remote Access

```bash
# With authentication
HUB_SECRET=your-secret bash scripts/start.sh

# With cloudflared tunnel
HUB_SECRET=your-secret HUB_TUNNEL=cloudflared bash scripts/start.sh
```

## Architecture

### Lazy Loading

Only **Boss + Hub + Monitor** start initially (1 Claude instance). Team members are spawned on demand when Boss decides they're needed — no wasted resources.

### Communication

- **#general** — Client ↔ Boss only (private line)
- **#proj-xxx** — Team discussions per project (all roles can @mention each other)
- **Monitor** — Auto-wakes idle bots, detects crashes, broadcasts typing indicators
- **WebSocket** — Real-time message delivery

### Role System

Roles are not hardcoded. `recruit.sh` calls Claude to generate a complete role definition:
- Personality, decision framework, communication style
- Tool permissions (CLAUDE.md frontmatter)
- Cross-project experience (accumulates over time)

Pre-built roles: Lead, Product Manager, Architect, Artist, Tester. Custom roles can be generated from any description.

```bash
# Reuse existing role
bash scripts/add-member.sh --reuse architect --project myapp

# Generate new specialist
bash scripts/add-member.sh "Security auditor, OWASP expert" --project myapp
```

### Enforced Workflow

Every project must go through:
1. **Requirements** (Product leads) → User scenarios, priorities, acceptance criteria
2. **Design** (Artist leads, if applicable) → Visual style, layout, interaction
3. **Technical Plan** (Architect leads) → Stack, modules, risks
4. **Decision** (Lead synthesizes) → Written to `decisions/`
5. **Execution** → Code written via Workers
6. **Review** → Against acceptance criteria

Skipping steps is explicitly forbidden in the Boss instructions.

### Memory & Experience

| Layer | Scope | Mechanism |
|-------|-------|-----------|
| Individual | Per bot, persists across conversations | Claude Code auto-memory |
| Team | Per project | `workspace/team-knowledge/` |
| Cross-project | Per role, accumulates forever | `roles/<id>.experience.md` |

Roles get stronger with use — experience is saved before context compression and loaded when the role is reused.

## Phone UI Features

- **Channel tabs** — Switch between #general and project channels
- **Real-time messages** — WebSocket push, @mention highlighting
- **Notifications** — Sound + vibration + browser push when @client is mentioned
- **Typing indicators** — See which bot is processing
- **Unread badges** — Red dots on channels with new messages
- **Stop project** — ■ button to interrupt ongoing work
- **Export logs** — 📄 button to download conversation as Markdown
- **Multi-language** — Auto-detects zh-CN / en / ja

## Logging

All components write structured JSON logs to `data/logs/`:

```bash
# Today's activity
cat data/logs/*-$(date +%Y-%m-%d).log | sort

# Errors only
grep '"ERROR"' data/logs/*.log

# Performance (response times, task durations)
grep '"perf"' data/logs/hub-*.log

# Specific bot
cat data/logs/mcp-architect-*.log
```

## Scripts Reference

| Script | Description |
|--------|-------------|
| `start.sh` | Start Hub + Boss + Monitor (team on demand) |
| `stop.sh` | Stop everything |
| `add-member.sh` | Add a role to running team |
| `recruit.sh` | Generate/reuse role definition |
| `list-roles.sh` | List reusable roles |
| `monitor.sh` | Auto-wake + crash recovery daemon |
| `wake.sh` | Manually wake specific bots |
| `export-log.sh` | Export channel conversations to Markdown |
| `worker.sh` | Dispatch tasks to temporary Claude processes |

## Configuration

### team.json

```json
{
  "project": "my-project",
  "hub": {
    "port": 7800,
    "secret": "",
    "default_channel": "general"
  },
  "slots": []
}
```

Slots are populated automatically by `add-member.sh` — don't edit manually.

## License

MIT
