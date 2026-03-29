#!/bin/bash
# 项目复盘 — 让所有参与角色总结经验教训
#
# 用法:
#   bash scripts/debrief.sh <项目名>
#   bash scripts/debrief.sh snake
#
# 流程:
#   1. 在项目频道发复盘请求
#   2. Monitor 自动唤醒各角色
#   3. 等待各角色回复经验总结
#   4. 收集到 projects/<名>/workspace/retrospective.md
#   5. 追加到各角色的 experience 文件
#   6. 导出项目纪要

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_FILE="$PROJECT_DIR/team.json"
ROLES_DIR="$PROJECT_DIR/roles"

# Load i18n
source "$PROJECT_DIR/scripts/i18n.sh"

PROJECT_NAME="${1:?Usage: bash scripts/debrief.sh <project-name>}"
CHANNEL="proj-${PROJECT_NAME}"
PROJECT_WORKSPACE="$PROJECT_DIR/projects/${PROJECT_NAME}/workspace"
RETRO_FILE="$PROJECT_WORKSPACE/retrospective.md"

HUB_PORT=$(jq -r '.hub.port // 7800' "$TEAM_FILE")
HUB_URL="http://127.0.0.1:${HUB_PORT}"

# 检查 Hub
if ! curl -sf "${HUB_URL}/api/health" >/dev/null 2>&1; then
    echo "Error: Hub not running"
    exit 1
fi

# 检查频道存在
MSG_COUNT=$(curl -sf "${HUB_URL}/api/channels" | jq --arg ch "$CHANNEL" '[.[] | select(.name == $ch)] | length' 2>/dev/null || echo 0)
if [ "$MSG_COUNT" -eq 0 ]; then
    echo "Error: Channel #${CHANNEL} not found"
    exit 1
fi

echo "========================================="
echo "  Project Debrief: $PROJECT_NAME"
echo "========================================="
echo ""

# 获取当前频道所有 bot（从消息中提取）
BOTS=$(curl -sf "${HUB_URL}/api/messages/${CHANNEL}?limit=100" | jq -r '[.[].bot_id] | unique | .[] | select(. != "client" and . != "boss")' 2>/dev/null)

if [ -z "$BOTS" ]; then
    echo "No team members found in #${CHANNEL}"
    exit 1
fi

echo "Team members: $BOTS"
echo ""

# 发复盘请求
MENTION_ALL=""
for bot in $BOTS; do
    MENTION_ALL="${MENTION_ALL} @${bot}"
done

DEBRIEF_MSG="📝 **Project Debrief — ${PROJECT_NAME}**

Project is wrapping up. Each team member, please summarize your experience:

1. **What went well** — decisions/approaches that worked
2. **What went wrong** — mistakes, surprises, things you'd do differently
3. **Key lessons** — specific, actionable takeaways for future projects
4. **Collaboration notes** — what worked/didn't work in team communication

${MENTION_ALL}

Reply in this channel. Keep it concise (3-5 bullet points each)."

curl -sf -X POST "${HUB_URL}/api/messages" \
    -H 'Content-Type: application/json' -H 'x-bot-id: boss' \
    -d "$(jq -n --arg ch "$CHANNEL" --arg text "$DEBRIEF_MSG" '{channel: $ch, text: $text}')" \
    >/dev/null

echo "Debrief request sent to #${CHANNEL}"
echo "Waiting for responses (5 minutes)..."
echo ""

# 记录发送时间
SEND_TIME=$(date +%s)

# 等待回复（每 30 秒检查一次）
RESPONDED=""
for i in $(seq 1 10); do
    sleep 30

    # 检查新消息
    MSGS=$(curl -sf "${HUB_URL}/api/messages/${CHANNEL}?limit=50")

    for bot in $BOTS; do
        # 检查是否已回复
        if echo "$RESPONDED" | grep -q "$bot"; then continue; fi

        HAS_REPLY=$(echo "$MSGS" | jq --arg bot "$bot" --arg ts "$(date -d @$SEND_TIME +%Y-%m-%dT%H:%M:%S)" '
            [.[] | select(.bot_id == $bot and .ts > $ts)] | length
        ' 2>/dev/null || echo 0)

        if [ "$HAS_REPLY" -gt 0 ]; then
            RESPONDED="${RESPONDED} ${bot}"
            echo "  ✅ $bot responded"
        fi
    done

    # 检查是否所有人都回复了
    ALL_DONE=true
    for bot in $BOTS; do
        if ! echo "$RESPONDED" | grep -q "$bot"; then
            ALL_DONE=false
            break
        fi
    done

    if [ "$ALL_DONE" = true ]; then
        echo ""
        echo "All team members responded!"
        break
    fi
done

echo ""

# 收集回复到 retrospective.md
mkdir -p "$PROJECT_WORKSPACE"

echo "# Project Retrospective: ${PROJECT_NAME}" > "$RETRO_FILE"
echo "" >> "$RETRO_FILE"
echo "Date: $(date +%Y-%m-%d)" >> "$RETRO_FILE"
echo "" >> "$RETRO_FILE"

# 获取复盘后的所有消息
MSGS=$(curl -sf "${HUB_URL}/api/messages/${CHANNEL}?limit=100")

for bot in $BOTS; do
    REPLY=$(echo "$MSGS" | jq -r --arg bot "$bot" --arg ts "$(date -d @$SEND_TIME +%Y-%m-%dT%H:%M:%S)" '
        [.[] | select(.bot_id == $bot and .ts > $ts)] | .[-1].text // ""
    ' 2>/dev/null)

    if [ -n "$REPLY" ] && [ "$REPLY" != "" ]; then
        echo "## $bot" >> "$RETRO_FILE"
        echo "" >> "$RETRO_FILE"
        echo "$REPLY" >> "$RETRO_FILE"
        echo "" >> "$RETRO_FILE"

        # 追加到角色经验文件
        EXP_FILE="$ROLES_DIR/${bot}.experience.md"
        {
            echo ""
            echo "## $(date +%Y-%m-%d) — ${PROJECT_NAME} — Project Debrief"
            echo ""
            echo "$REPLY"
        } >> "$EXP_FILE"
        echo "  📚 $bot experience saved"
    fi
done

echo ""

# 导出完整项目纪要
bash "$PROJECT_DIR/scripts/export-log.sh" --project "$PROJECT_NAME" \
    -o "$PROJECT_WORKSPACE/project-minutes.md" 2>/dev/null || true

echo ""
echo "========================================="
echo "  Debrief complete!"
echo "========================================="
echo ""
echo "Files:"
echo "  Retrospective:   $RETRO_FILE"
echo "  Project minutes: $PROJECT_WORKSPACE/project-minutes.md"
echo "  Experience files: roles/<role>.experience.md"
