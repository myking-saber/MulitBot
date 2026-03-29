---
name: configure
description: Set up a multibot-discord instance — save bot token, set role, review access. Supports DISCORD_STATE_DIR for multi-bot isolation.
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash(ls *)
  - Bash(mkdir *)
---

# /multibot-discord:configure — Multi-Bot Discord Setup

Writes bot token and optional role config. State dir is determined by:
1. `DISCORD_STATE_DIR` env var (if set)
2. Otherwise `~/.claude/channels/discord/`

Arguments passed: `$ARGUMENTS`

---

## Determine state dir

```bash
STATE_DIR="${DISCORD_STATE_DIR:-$HOME/.claude/channels/discord}"
ENV_FILE="$STATE_DIR/.env"
ACCESS_FILE="$STATE_DIR/access.json"
```

Log which dir you're operating on.

## Dispatch on arguments

### No args — status and guidance

1. **State dir** — show which directory this instance uses.
2. **Token** — check `.env` for `DISCORD_BOT_TOKEN`. Show set/not-set.
3. **Role** — check `.env` for `BOT_ROLE`. Show if set.
4. **Access** — read `access.json`, show policy, allowlist, pending.
5. **What next** — guide based on state:
   - No token → "Run `/multibot-discord:configure <token>` with your bot token"
   - No role → "Optionally set role with `/multibot-discord:configure role <name>`"
   - Ready → "Start with: `DISCORD_STATE_DIR=<dir> claude --channels ...`"

### `<token>` — save token

1. Treat `$ARGUMENTS` as token (trim whitespace). Discord tokens start `MT` or `Nz`.
2. `mkdir -p <state_dir>`
3. Read existing `.env` if present; update/add `DISCORD_BOT_TOKEN=` line. Preserve other keys.
4. Write back. Confirm.

### `role <role_name>` — set bot role

1. Read existing `.env`.
2. Update/add `BOT_ROLE=<role_name>` line.
3. Write back. Confirm.

### `clear` — remove token

Delete the `DISCORD_BOT_TOKEN=` line.

---

## Multi-bot quick setup guide

When user asks about multi-bot setup, show this:

```bash
# 1. Create isolated state dirs
mkdir -p ~/.claude/channels/discord-lead
mkdir -p ~/.claude/channels/discord-product

# 2. Configure each bot
DISCORD_STATE_DIR=~/.claude/channels/discord-lead /multibot-discord:configure <lead-token>
DISCORD_STATE_DIR=~/.claude/channels/discord-lead /multibot-discord:configure role lead

# 3. Start each in separate terminals
DISCORD_STATE_DIR=~/.claude/channels/discord-lead \
  DISCORD_BOT_TOKEN=<lead-token> \
  BOT_ROLE=lead \
  claude --channels plugin:multibot-discord@local
```

## Implementation notes

- Server reads `.env` at boot — token changes need session restart.
- `access.json` is re-read on every inbound message — policy changes take effect immediately.
- Always show state dir path so user knows which bot instance they're configuring.
