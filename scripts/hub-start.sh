#!/bin/bash
# Start Hub message server

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HUB_DIR="$PROJECT_DIR/plugins/multibot-hub"
SESSION_NAME="mulit-bot"

# Load i18n
source "$PROJECT_DIR/scripts/i18n.sh"

export HUB_PORT="${HUB_PORT:-7800}"
export HUB_HOST="${HUB_HOST:-0.0.0.0}"
export HUB_DATA_DIR="${HUB_DATA_DIR:-$PROJECT_DIR/data}"

# Check if already running
if curl -sf "http://127.0.0.1:${HUB_PORT}/api/health" >/dev/null 2>&1; then
    echo "$L_HUB_RUNNING (port $HUB_PORT)"
    curl -s "http://127.0.0.1:${HUB_PORT}/api/health" | python3 -m json.tool 2>/dev/null || true
    exit 0
fi

# Check bun
if ! command -v bun &> /dev/null; then
    echo "$L_ERR_NEED bun (https://bun.sh)"
    exit 1
fi

# Install dependencies
if [ ! -d "$HUB_DIR/node_modules" ]; then
    echo "Installing dependencies..."
    cd "$HUB_DIR" && bun install 2>/dev/null || true
fi

# Start Hub in tmux
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux new-window -t "$SESSION_NAME" -n "hub" 2>/dev/null || true
    tmux send-keys -t "$SESSION_NAME:hub" \
        "cd $HUB_DIR && HUB_PORT=$HUB_PORT HUB_HOST=$HUB_HOST HUB_DATA_DIR=$HUB_DATA_DIR HUB_SECRET='${HUB_SECRET:-}' HUB_TUNNEL='${HUB_TUNNEL:-}' bun run hub.ts" \
        Enter
    echo "Hub $L_STARTED (tmux: $SESSION_NAME:hub)"
else
    tmux new-session -d -s "$SESSION_NAME" -n "hub"
    tmux send-keys -t "$SESSION_NAME:hub" \
        "cd $HUB_DIR && HUB_PORT=$HUB_PORT HUB_HOST=$HUB_HOST HUB_DATA_DIR=$HUB_DATA_DIR HUB_SECRET='${HUB_SECRET:-}' HUB_TUNNEL='${HUB_TUNNEL:-}' bun run hub.ts" \
        Enter
    echo "Hub $L_STARTED (tmux: $SESSION_NAME:hub, new session)"
fi

# Wait for Hub ready
echo -n "$L_HUB_READY"
for i in $(seq 1 15); do
    if curl -sf "http://127.0.0.1:${HUB_PORT}/api/health" >/dev/null 2>&1; then
        echo " ✅"
        echo ""
        echo "Hub:    http://127.0.0.1:${HUB_PORT}"

        LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$LAN_IP" ] && echo "LAN:    http://${LAN_IP}:${HUB_PORT}"

        if [ -n "$HUB_SECRET" ]; then
            echo ""
            echo "$L_PHONE: http://${LAN_IP:-localhost}:${HUB_PORT}?secret=${HUB_SECRET}"
        fi
        exit 0
    fi
    echo -n "."
    sleep 1
done

echo " ❌ $L_HUB_TIMEOUT"
echo "Log: tmux attach -t $SESSION_NAME:hub"
exit 1
