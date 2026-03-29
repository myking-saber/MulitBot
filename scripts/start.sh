#!/bin/bash
# Start MulitBot — Hub + Boss + Monitor (team on demand)
#
# Usage:
#   bash scripts/start.sh                # Start from team.json
#   bash scripts/start.sh --hub-only     # Start Hub only

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_FILE="$PROJECT_DIR/team.json"
PLUGIN_DIR="$PROJECT_DIR/plugins/multibot-hub"
SESSION_NAME="mulit-bot"
LOG_DIR="$PROJECT_DIR/data/logs"
mkdir -p "$LOG_DIR"

# Load i18n
source "$PROJECT_DIR/scripts/i18n.sh"

# Clean up stale session if Hub is dead
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    if ! curl -sf "http://127.0.0.1:${HUB_PORT:-7800}/api/health" >/dev/null 2>&1; then
        tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
        sleep 1
    fi
fi

slog() {
    local ts=$(date +%Y-%m-%dT%H:%M:%S)
    echo "{\"ts\":\"${ts}\",\"level\":\"$1\",\"cat\":\"start\",\"msg\":\"$2\"}" >> "$LOG_DIR/system-$(date +%Y-%m-%d).log"
}

# Check dependencies
for cmd in tmux jq bun; do
    if ! command -v $cmd &> /dev/null; then
        echo "$L_ERR_NEED $cmd"
        exit 1
    fi
done

# Parse args
if [ "$1" = "--hub-only" ]; then
    bash "$PROJECT_DIR/scripts/hub-start.sh"
    exit $?
fi

if [ ! -f "$TEAM_FILE" ]; then
    echo "$L_ERR_MISSING $TEAM_FILE"
    exit 1
fi

# Validate team.json
if ! jq -e '.hub' "$TEAM_FILE" >/dev/null 2>&1; then
    echo "$L_ERR_NO_HUB"
    echo "$L_AUTO_FIX"
    TMP=$(mktemp)
    jq '. + {"hub": {"port": 7800, "secret": "", "default_channel": "general"}}' "$TEAM_FILE" > "$TMP" && mv "$TMP" "$TEAM_FILE"
    echo "$L_HUB_FIX_DONE"
fi

if ! jq -e '.slots' "$TEAM_FILE" >/dev/null 2>&1; then
    echo "$L_ERR_NO_SLOTS"
    exit 1
fi

# Read Hub config
HUB_PORT=$(jq -r '.hub.port // 7800' "$TEAM_FILE")
HUB_SECRET=$(jq -r '.hub.secret // ""' "$TEAM_FILE")
HUB_CHANNEL=$(jq -r '.hub.default_channel // "general"' "$TEAM_FILE")
PROJECT_NAME=$(jq -r '.project // "MulitBot"' "$TEAM_FILE")

export HUB_PORT HUB_SECRET

echo "========================================="
echo "  MulitBot: $PROJECT_NAME"
echo "========================================="
echo ""

# Step 1: Start Hub
echo "[1/3] $L_HUB_STARTING"
bash "$PROJECT_DIR/scripts/hub-start.sh"
echo ""

# Step 2: Start Boss
echo "[2/3] $L_BOT_STARTING"

# Select Boss CLAUDE.md by language
LANG_CODE=$(jq -r '.lang // ""' "$TEAM_FILE" 2>/dev/null)
if [ -z "$LANG_CODE" ]; then
    case "${LANG:-${LC_ALL:-en}}" in
        zh*) LANG_CODE="zh-CN" ;;
        ja*) LANG_CODE="ja" ;;
        *) LANG_CODE="en" ;;
    esac
fi
case "$LANG_CODE" in
    zh*) LANG_KEY="zh-CN" ;;
    ja*) LANG_KEY="ja" ;;
    *) LANG_KEY="en" ;;
esac

BOSS_DIR="$PROJECT_DIR/bots/boss"

# Apply language-specific Boss instructions
BOSS_I18N="$BOSS_DIR/i18n/CLAUDE.${LANG_KEY}.md"
if [ -f "$BOSS_I18N" ]; then
    cp "$BOSS_I18N" "$BOSS_DIR/CLAUDE.md"
    slog "INFO" "Boss language: $LANG_KEY"
fi

# Ensure .mcp.json
if [ ! -f "$BOSS_DIR/.mcp.json" ]; then
    cat > "$BOSS_DIR/.mcp.json" << MCPEOF
{
  "mcpServers": {
    "multibot-hub": {
      "command": "bun",
      "args": ["run", "${PLUGIN_DIR}/server.ts"]
    }
  }
}
MCPEOF
fi

tmux new-window -t "$SESSION_NAME" -n "boss" 2>/dev/null || true
tmux send-keys -t "$SESSION_NAME:boss" \
    "cd $BOSS_DIR && HUB_URL=http://127.0.0.1:${HUB_PORT} HUB_SECRET='${HUB_SECRET}' BOT_ID='boss' BOT_ROLE='Boss' MENTION_MODE='all' HUB_CHANNEL='${HUB_CHANNEL}' claude --dangerously-skip-permissions" \
    Enter
slog "INFO" "Boss started (lang=$LANG_KEY)"
echo "  ✅ $L_BOT_BOSS | mode=all"

# Team members start on demand via add-member.sh
echo "  $L_BOT_ONDEMAND"

echo ""

# Step 3: Wait for Boss init + start Monitor
echo "[3/3] $L_WAITING_INIT"
sleep 10

tmux new-window -t "$SESSION_NAME" -n "monitor" 2>/dev/null || true
tmux send-keys -t "$SESSION_NAME:monitor" \
    "bash $PROJECT_DIR/scripts/monitor.sh --interval 10" Enter
slog "INFO" "Monitor started, system ready"
echo "  $L_MONITOR_STARTED (10s)"

echo ""
echo "========================================="
echo "  $L_TEAM_STARTED"
echo "========================================="
echo ""
echo "Hub:    http://127.0.0.1:${HUB_PORT}"
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$LAN_IP" ] && echo "$L_PHONE:   http://${LAN_IP}:${HUB_PORT}${HUB_SECRET:+?secret=$HUB_SECRET}"
echo ""
echo "$L_MANAGE:   tmux attach -t $SESSION_NAME"
echo "$L_STOP_CMD:   bash scripts/stop.sh"
