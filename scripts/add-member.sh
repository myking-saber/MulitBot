#!/bin/bash
# 动态添加团队成员 — 在运行中的团队里加入新角色
#
# 用法:
#   bash scripts/add-member.sh "角色描述"              # 新招聘
#   bash scripts/add-member.sh --reuse <role-id>       # 复用已有角色
#   bash scripts/add-member.sh --reuse architect --project snake  # 指定项目

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_FILE="$PROJECT_DIR/team.json"
PLUGIN_DIR="$PROJECT_DIR/plugins/multibot-hub"
SESSION_NAME="mulit-bot"

# 解析参数
REUSE_ID=""
SOUL_DESC=""
PROJECT_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reuse) REUSE_ID="$2"; shift 2 ;;
        --project) PROJECT_NAME="$2"; shift 2 ;;
        *) SOUL_DESC="$1"; shift ;;
    esac
done

if [ -z "$REUSE_ID" ] && [ -z "$SOUL_DESC" ]; then
    echo "用法:"
    echo "  bash scripts/add-member.sh \"角色描述\""
    echo "  bash scripts/add-member.sh --reuse <role-id>"
    echo "  bash scripts/add-member.sh --reuse <role-id> --project <项目名>"
    exit 1
fi

# 检查 tmux 会话存在
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "错误: 团队未运行，请先 bash scripts/start.sh"
    exit 1
fi

# 确定下一个 slot 号（如果 slots 为空则从 1 开始）
EXISTING_SLOTS=$(jq '.slots | length' "$TEAM_FILE")
if [ "$EXISTING_SLOTS" -eq 0 ]; then
    NEXT_SLOT=1
else
    NEXT_SLOT=$(jq '[.slots[].slot] | max + 1' "$TEAM_FILE")
fi

# 判断是否是 lead 角色
IS_LEAD="false"
if [ "$REUSE_ID" = "lead" ] || echo "$SOUL_DESC" | grep -qi "lead\|主持人\|协调者"; then
    IS_LEAD="true"
fi

# 跳过已运行的角色
if [ -n "$REUSE_ID" ]; then
    EXISTING=$(jq -r --arg id "$REUSE_ID" '.slots[] | select(.id == $id) | .id' "$TEAM_FILE")
    if [ -n "$EXISTING" ] && tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -q "^${REUSE_ID}$"; then
        echo "[add-member] $REUSE_ID 已在运行，跳过"
        exit 0
    fi
fi

# 招聘/复用
echo "[add-member] 招聘 slot $NEXT_SLOT (is_lead=$IS_LEAD)..."
if [ -n "$REUSE_ID" ]; then
    RESULT=$(bash "$PROJECT_DIR/scripts/recruit.sh" "$NEXT_SLOT" "$IS_LEAD" --reuse "$REUSE_ID" 2>&1)
    RC=$?
    ROLE_ID="$REUSE_ID"
else
    RESULT=$(bash "$PROJECT_DIR/scripts/recruit.sh" "$NEXT_SLOT" "$IS_LEAD" "$SOUL_DESC" 2>&1)
    RC=$?
    ROLE_ID=$(echo "$RESULT" | grep -o '"role_id":"[^"]*"' | cut -d'"' -f4)
fi
echo "$RESULT" | grep -E "✅|📚|角色:" >&2

if [ "$RC" -ne 0 ] || [ -z "$ROLE_ID" ]; then
    echo "错误: 招聘失败 (exit=$RC)" >&2
    echo "$RESULT" >&2
    exit 1
fi

# 更新 team.json
SOUL="${REUSE_ID:-$SOUL_DESC}"
TMP_FILE=$(mktemp)
jq --arg slot "$NEXT_SLOT" --arg id "$ROLE_ID" --arg soul "$SOUL" \
    '.slots += [{"slot": ($slot|tonumber), "id": $id, "role": "member", "soul": $soul}]' \
    "$TEAM_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$TEAM_FILE"
echo "[add-member] team.json 已更新"

# 读取 Hub 配置
HUB_PORT=$(jq -r '.hub.port // 7800' "$TEAM_FILE")
HUB_SECRET=$(jq -r '.hub.secret // ""' "$TEAM_FILE")
HUB_CHANNEL=$(jq -r '.hub.default_channel // "general"' "$TEAM_FILE")

# 读取角色信息
BOT_DIR="$PROJECT_DIR/bots/${ROLE_ID}"
CLAUDE_MD="$BOT_DIR/CLAUDE.md"
ROLE_NAME=$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$CLAUDE_MD")
MENTION_MODE=$(awk '/^mention_mode:/{sub(/^mention_mode:[[:space:]]*/,""); print; exit}' "$CLAUDE_MD")

# 构建 .mcp.json = Hub MCP + 共享 MCP 技能
SHARED_MCP="$PROJECT_DIR/mcp-shared.json"
HUB_MCP="{\"multibot-hub\":{\"command\":\"bun\",\"args\":[\"run\",\"${PLUGIN_DIR}/server.ts\"]}}"

if [ -f "$SHARED_MCP" ]; then
    # 合并：Hub MCP + shared MCP 中配置了的服务（过滤掉没有 API key 等空配置的）
    MERGED=$(jq --argjson hub "$HUB_MCP" '
        { mcpServers: (.mcpServers | to_entries | map(
            select(.value.env == null or (.value.env | to_entries | all(.value != "")))
            | {key: .key, value: (.value | del(.roles, .description))}
        ) | from_entries) } | .mcpServers += $hub
    ' "$SHARED_MCP" 2>/dev/null)
    if [ -n "$MERGED" ]; then
        echo "{\"mcpServers\": $MERGED}" | jq '.' > "$BOT_DIR/.mcp.json"
    else
        echo "{\"mcpServers\": $HUB_MCP}" | jq '.' > "$BOT_DIR/.mcp.json"
    fi
else
    echo "{\"mcpServers\": $HUB_MCP}" | jq '.' > "$BOT_DIR/.mcp.json"
fi

# 启动 Claude Code 在新 tmux 窗口
tmux new-window -t "$SESSION_NAME" -n "$ROLE_ID" 2>/dev/null || true
tmux send-keys -t "$SESSION_NAME:$ROLE_ID" \
    "cd $BOT_DIR && HUB_URL=http://127.0.0.1:${HUB_PORT} HUB_SECRET='${HUB_SECRET}' BOT_ID='${ROLE_ID}' BOT_ROLE='${ROLE_NAME}' MENTION_MODE='${MENTION_MODE:-mention}' HUB_CHANNEL='${HUB_CHANNEL}' claude --dangerously-skip-permissions" \
    Enter
echo "[add-member] ✅ $ROLE_NAME ($ROLE_ID) 已启动"

# 重启 monitor 让它发现新成员
tmux send-keys -t "$SESSION_NAME:monitor" C-c 2>/dev/null || true
sleep 1
tmux send-keys -t "$SESSION_NAME:monitor" \
    "bash $PROJECT_DIR/scripts/monitor.sh --interval 10" Enter 2>/dev/null || true
echo "[add-member] Monitor 已重启"

# 在项目频道通知
sleep 2
CHANNEL="${HUB_CHANNEL}"
if [ -n "$PROJECT_NAME" ]; then
    CHANNEL="proj-${PROJECT_NAME}"
fi
curl -sf -X POST "http://127.0.0.1:${HUB_PORT}/api/messages" \
    -H 'Content-Type: application/json' -H 'x-bot-id: boss' \
    -d "{\"channel\":\"${CHANNEL}\",\"text\":\"新成员加入：@${ROLE_ID}（${ROLE_NAME}），请 @lead 安排对接。\"}" \
    >/dev/null 2>&1 || true

echo ""
echo "========================================="
echo "  ✅ $ROLE_NAME ($ROLE_ID) 已加入团队"
echo "========================================="
