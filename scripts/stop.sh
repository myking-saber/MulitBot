#!/bin/bash
# Stop MulitBot — Hub + all Bots + Monitor

SESSION_NAME="mulit-bot"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PROJECT_DIR/data/logs"
mkdir -p "$LOG_DIR"

# Load i18n
source "$PROJECT_DIR/scripts/i18n.sh"

slog() {
    local ts=$(date +%Y-%m-%dT%H:%M:%S)
    echo "{\"ts\":\"${ts}\",\"level\":\"$1\",\"cat\":\"stop\",\"msg\":\"$2\"}" >> "$LOG_DIR/system-$(date +%Y-%m-%d).log"
}

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "$L_NO_SESSION"
    exit 0
fi

echo "MulitBot $L_STOPPING..."

WINDOWS=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null)

for window in $WINDOWS; do
    echo "  $L_CLOSING $window..."
    if [ "$window" = "hub" ]; then
        tmux send-keys -t "$SESSION_NAME:$window" C-c
    elif [ "$window" = "monitor" ]; then
        tmux send-keys -t "$SESSION_NAME:$window" C-c
    else
        tmux send-keys -t "$SESSION_NAME:$window" "/exit" Enter
    fi
done

sleep 3

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux kill-session -t "$SESSION_NAME"
    echo "  $L_SESSION_KILLED"
fi

slog "INFO" "All processes stopped"
echo "$L_ALL_STOPPED"
