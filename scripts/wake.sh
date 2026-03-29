#!/bin/bash
# 唤醒团队 — 通知所有 Bot 检查频道消息
#
# 用法:
#   bash scripts/wake.sh                  # 唤醒所有 Bot
#   bash scripts/wake.sh lead architect   # 只唤醒指定 Bot

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_FILE="$PROJECT_DIR/team.json"
SESSION_NAME="mulit-bot"
HUB_CHANNEL=$(jq -r '.hub.default_channel // "general"' "$TEAM_FILE")

INIT_MSG="你已上线。请立即用 fetch_messages 工具（MCP 工具，不是 curl）检查 ${HUB_CHANNEL} 频道的消息，根据消息内容行动。收到新消息后会通过 WebSocket 自动推送，届时请再次 fetch_messages 获取最新消息并响应。"

if [ $# -gt 0 ]; then
    # 唤醒指定 Bot
    for bot in "$@"; do
        tmux send-keys -t "$SESSION_NAME:$bot" "$INIT_MSG" Enter 2>/dev/null && \
            echo "📨 $bot: 已唤醒" || echo "❌ $bot: 窗口不存在"
        sleep 2
    done
else
    # 唤醒所有 Bot
    SLOT_COUNT=$(jq '.slots | length' "$TEAM_FILE")
    for ((i=0; i<SLOT_COUNT; i++)); do
        slot_id=$(jq -r ".slots[$i].id // \"\"" "$TEAM_FILE")
        WINDOW_NAME="${slot_id:-slot-$(jq -r ".slots[$i].slot" "$TEAM_FILE")}"
        tmux send-keys -t "$SESSION_NAME:$WINDOW_NAME" "$INIT_MSG" Enter 2>/dev/null && \
            echo "📨 $WINDOW_NAME: 已唤醒" || echo "❌ $WINDOW_NAME: 窗口不存在"
        sleep 2
    done
fi
