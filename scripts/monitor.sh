#!/bin/bash
# MulitBot 消息监控守护进程
# 持续监控 Hub 消息，自动唤醒有未读 @mention 的 Bot
#
# 用法:
#   bash scripts/monitor.sh              # 默认 10 秒轮询
#   bash scripts/monitor.sh --interval 5 # 5 秒轮询
#
# 通常由 start.sh 在 tmux 的 monitor 窗口中自动启动

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_FILE="$PROJECT_DIR/team.json"
SESSION_NAME="mulit-bot"
LOG_DIR="$PROJECT_DIR/data/logs"
mkdir -p "$LOG_DIR"

# 日志函数：同时输出到终端和文件
mlog() {
    local level="$1" msg="$2"
    local ts=$(date +%Y-%m-%dT%H:%M:%S)
    local line="{\"ts\":\"${ts}\",\"level\":\"${level}\",\"cat\":\"monitor\",\"msg\":\"${msg}\"}"
    echo "$line" >> "$LOG_DIR/monitor-$(date +%Y-%m-%d).log"
    echo "[$(date +%H:%M:%S)] ${msg}"
}
POLL_INTERVAL=10

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) POLL_INTERVAL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

HUB_PORT=$(jq -r '.hub.port // 7800' "$TEAM_FILE")
HUB_URL="http://127.0.0.1:${HUB_PORT}"
HUB_CHANNEL=$(jq -r '.hub.default_channel // "general"' "$TEAM_FILE")

# 每个 bot 的最后处理消息 ID
declare -A LAST_SEEN

# 获取所有频道名
get_channels() {
    curl -sf "${HUB_URL}/api/channels" 2>/dev/null | jq -r '.[].name' 2>/dev/null || echo ""
}

# 获取频道消息
get_messages() {
    local channel="$1"
    curl -sf "${HUB_URL}/api/messages/${channel}?limit=50" 2>/dev/null || echo "[]"
}

# 检查 bot 的 tmux 窗口是否在空闲状态（显示 ❯ 提示符）
is_bot_idle() {
    local bot_id="$1"
    local pane_content
    pane_content=$(tmux capture-pane -t "$SESSION_NAME:$bot_id" -p -S -5 2>/dev/null || echo "")
    # 检查是否有 ❯ 提示符且没有 "Do you want to proceed" 权限提示
    if echo "$pane_content" | grep -q "❯" && ! echo "$pane_content" | grep -q "Do you want to proceed"; then
        return 0  # idle
    fi
    return 1  # busy
}

# 检查 bot 是否崩溃（claude 进程不存在）
is_bot_crashed() {
    local bot_id="$1"
    # 检查 tmux 窗口是否存在
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then return 1; fi
    if ! tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -q "^${bot_id}$"; then
        return 0  # 窗口不存在 = 崩溃
    fi
    # 检查窗口内是否有 claude 进程
    local pane_pid
    pane_pid=$(tmux list-panes -t "$SESSION_NAME:$bot_id" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -z "$pane_pid" ]; then return 0; fi
    # 检查是否有 claude 子进程
    if pgrep -P "$pane_pid" -f "claude" >/dev/null 2>&1; then
        return 1  # 正常运行
    fi
    # 二次确认：pane 显示 $ 提示符而非 ❯
    local pane_content
    pane_content=$(tmux capture-pane -t "$SESSION_NAME:$bot_id" -p -S -3 2>/dev/null || echo "")
    if echo "$pane_content" | grep -q '^\$\|zengjiancan@'; then
        return 0  # 崩溃
    fi
    return 1  # 不确定，当作正常
}

# 重启崩溃的 bot
restart_bot() {
    local bot_id="$1"
    local bot_dir="$PROJECT_DIR/bots/${bot_id}"
    local hub_port=$(jq -r '.hub.port // 7800' "$TEAM_FILE")
    local hub_secret=$(jq -r '.hub.secret // ""' "$TEAM_FILE")
    local hub_channel=$(jq -r '.hub.default_channel // "general"' "$TEAM_FILE")
    local role_name=$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$bot_dir/CLAUDE.md" 2>/dev/null)
    local mention_mode=$(awk '/^mention_mode:/{sub(/^mention_mode:[[:space:]]*/,""); print; exit}' "$bot_dir/CLAUDE.md" 2>/dev/null)

    # Boss is special — no frontmatter
    [ -z "$role_name" ] && role_name="$bot_id"
    [ -z "$mention_mode" ] && mention_mode="all"

    mlog "WARN" "restart $bot_id ($role_name)..."

    # 重建窗口（如果不存在）
    tmux new-window -t "$SESSION_NAME" -n "$bot_id" 2>/dev/null || true
    tmux send-keys -t "$SESSION_NAME:$bot_id" \
        "cd $bot_dir && HUB_URL=http://127.0.0.1:${hub_port} HUB_SECRET='${hub_secret}' BOT_ID='${bot_id}' BOT_ROLE='${role_name}' MENTION_MODE='${mention_mode:-mention}' HUB_CHANNEL='${hub_channel}' claude --dangerously-skip-permissions" \
        Enter

    LAST_RESTART["$bot_id"]=$(date +%s)
    mlog "WARN" "$bot_id 已重启，15s 后唤醒"
}

declare -A LAST_RESTART
declare -A WAKE_TIME  # 记录唤醒时间，用于计算响应耗时

# 唤醒 bot
wake_bot() {
    local bot_id="$1"
    local channel="$2"
    local msg_preview="$3"

    # 广播 typing 事件到 Web UI（让客户看到 "xxx 正在处理..."）
    curl -sf -X POST "${HUB_URL}/api/typing" \
        -H 'Content-Type: application/json' \
        -d "{\"bot_id\":\"${bot_id}\",\"channel\":\"${channel}\"}" \
        >/dev/null 2>&1 || true

    local wake_msg="频道 #${channel} 有新消息 @你：${msg_preview}。请用 fetch_messages 工具检查 ${channel} 频道的最新消息并响应。"

    tmux send-keys -t "$SESSION_NAME:$bot_id" "$wake_msg" Enter 2>/dev/null
    WAKE_TIME["$bot_id"]=$(date +%s)
    mlog "INFO" "唤醒 $bot_id ← #$channel: ${msg_preview:0:60}"
}

echo "======================================="
echo "  MulitBot Monitor 启动"
echo "  轮询间隔: ${POLL_INTERVAL}s"
echo "  Hub: ${HUB_URL}"
echo "======================================="
echo ""

# 读取团队成员列表（包括 boss）
declare -A BOT_IDS
declare -A BOT_MODES

# Boss 始终被监控
BOT_IDS[boss]="boss"
BOT_MODES[boss]="all"
echo "监控: boss (mode=all)"

SLOT_COUNT=$(jq '.slots | length' "$TEAM_FILE")
for ((i=0; i<SLOT_COUNT; i++)); do
    bot_id=$(jq -r ".slots[$i].id // \"\"" "$TEAM_FILE")
    if [ -n "$bot_id" ]; then
        BOT_IDS[$bot_id]="$bot_id"
        # 读取 mention_mode
        claude_md="$PROJECT_DIR/bots/${bot_id}/CLAUDE.md"
        mode=$(awk '/^mention_mode:/{sub(/^mention_mode:[[:space:]]*/,""); print; exit}' "$claude_md" 2>/dev/null)
        BOT_MODES[$bot_id]="${mode:-mention}"
        echo "监控: $bot_id (mode=${BOT_MODES[$bot_id]})"
    fi
done
echo ""

# 初始化：记录当前最新消息 ID，避免唤醒历史消息
for channel in $(get_channels); do
    msgs=$(get_messages "$channel")
    last_id=$(echo "$msgs" | jq -r '.[-1].id // ""' 2>/dev/null)
    if [ -n "$last_id" ]; then
        for bot_id in "${BOT_IDS[@]}"; do
            LAST_SEEN["${bot_id}:${channel}"]="$last_id"
        done
    fi
done
mlog "INFO" "初始化完成，开始监控..."
echo ""

# 主循环
while true; do
    sleep "$POLL_INTERVAL"

    # 检查 Hub 是否存活
    if ! curl -sf "${HUB_URL}/api/health" >/dev/null 2>&1; then
        continue
    fi

    # 崩溃检测与自动重启
    for bot_id in "${BOT_IDS[@]}"; do
        if is_bot_crashed "$bot_id"; then
            local_now=$(date +%s)
            local_last="${LAST_RESTART[$bot_id]:-0}"
            if (( local_now - local_last > 60 )); then
                restart_bot "$bot_id"
                # 15s 后唤醒，让它 fetch 历史消息
                (sleep 15 && wake_bot "$bot_id" "$HUB_CHANNEL" "你刚被重启，请检查所有频道最新消息" || mlog "ERROR" "重启后唤醒 $bot_id 失败") &
            fi
        fi
    done

    # 遍历所有频道
    for channel in $(get_channels); do
        msgs=$(get_messages "$channel")
        msg_count=$(echo "$msgs" | jq 'length' 2>/dev/null || echo 0)
        [ "$msg_count" -eq 0 ] && continue

        # 遍历所有 bot
        for bot_id in "${BOT_IDS[@]}"; do
            # #general 是客户-老板专线，只唤醒 boss
            if [ "$channel" = "$HUB_CHANNEL" ] && [ "$bot_id" != "boss" ]; then
                # 更新 last_seen 但不唤醒
                latest_id=$(echo "$msgs" | jq -r '.[-1].id // ""' 2>/dev/null)
                [ -n "$latest_id" ] && LAST_SEEN["${bot_id}:${channel}"]="$latest_id"
                continue
            fi

            last_seen="${LAST_SEEN["${bot_id}:${channel}"]:-}"
            mode="${BOT_MODES[$bot_id]}"

            # 找到 last_seen 之后的新消息
            new_msgs=$(echo "$msgs" | jq -c --arg last "$last_seen" --arg bot "$bot_id" '
                [.[] | select(
                    (.bot_id != $bot) and                    # 不是自己发的
                    (if $last != "" then .id > $last else true end)  # 在 last_seen 之后
                )]
            ' 2>/dev/null || echo "[]")

            new_count=$(echo "$new_msgs" | jq 'length' 2>/dev/null || echo 0)
            [ "$new_count" -eq 0 ] && continue

            # 检查是否有和自己相关的消息
            relevant=false
            msg_preview=""

            if [ "$mode" = "all" ]; then
                # Lead 收所有消息
                relevant=true
                msg_preview=$(echo "$new_msgs" | jq -r '.[-1].text[:80]' 2>/dev/null)
            else
                # 其他角色只收 @自己 的消息
                mentioned=$(echo "$new_msgs" | jq -c --arg bot "$bot_id" '
                    [.[] | select(.mentions | index($bot))]
                ' 2>/dev/null || echo "[]")
                mention_count=$(echo "$mentioned" | jq 'length' 2>/dev/null || echo 0)
                if [ "$mention_count" -gt 0 ]; then
                    relevant=true
                    msg_preview=$(echo "$mentioned" | jq -r '.[-1].text[:80]' 2>/dev/null)
                fi
            fi

            if [ "$relevant" = true ]; then
                # 检查 bot 是否空闲
                if is_bot_idle "$bot_id"; then
                    wake_bot "$bot_id" "$channel" "$msg_preview"
                fi
            fi

            # 更新 last_seen 到最新消息
            latest_id=$(echo "$msgs" | jq -r '.[-1].id // ""' 2>/dev/null)
            [ -n "$latest_id" ] && LAST_SEEN["${bot_id}:${channel}"]="$latest_id"
        done

        # 检测 bot 回复——计算唤醒到回复的耗时
        for bot_id in "${BOT_IDS[@]}"; do
            wake_ts="${WAKE_TIME[$bot_id]:-0}"
            [ "$wake_ts" -eq 0 ] && continue
            # 检查这个 bot 是否在本频道发了新消息
            bot_replied=$(echo "$msgs" | jq -c --arg bot "$bot_id" --arg last "${LAST_SEEN["${bot_id}:${channel}_reply"]:-}" '
                [.[] | select(.bot_id == $bot and (if $last != "" then .id > $last else true end))]
            ' 2>/dev/null || echo "[]")
            reply_count=$(echo "$bot_replied" | jq 'length' 2>/dev/null || echo 0)
            if [ "$reply_count" -gt 0 ]; then
                now_ts=$(date +%s)
                latency=$((now_ts - wake_ts))
                mlog "INFO" "PERF $bot_id 响应耗时 ${latency}s (唤醒→回复) #$channel"
                WAKE_TIME["$bot_id"]=0
            fi
            # 记录已检查的回复位置
            reply_latest=$(echo "$bot_replied" | jq -r '.[-1].id // ""' 2>/dev/null)
            [ -n "$reply_latest" ] && LAST_SEEN["${bot_id}:${channel}_reply"]="$reply_latest"
        done
    done
done
