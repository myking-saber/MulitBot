#!/bin/bash
# 导出频道对话为可读的项目纪要
#
# 用法:
#   bash scripts/export-log.sh proj-snake              # 导出到 stdout
#   bash scripts/export-log.sh proj-snake -o report.md # 导出到文件
#   bash scripts/export-log.sh --all                   # 导出所有频道
#   bash scripts/export-log.sh --project snake         # 导出项目（general + proj-snake）

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$PROJECT_DIR/data"
CHANNELS_DIR="$DATA_DIR/channels"

OUTPUT=""
CHANNELS=()

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) OUTPUT="$2"; shift 2 ;;
        --all)
            for d in "$CHANNELS_DIR"/*/; do
                [ -d "$d" ] && CHANNELS+=("$(basename "$d")")
            done
            shift ;;
        --project)
            CHANNELS+=("general" "proj-$2")
            shift 2 ;;
        *) CHANNELS+=("$1"); shift ;;
    esac
done

if [ ${#CHANNELS[@]} -eq 0 ]; then
    echo "用法:"
    echo "  bash scripts/export-log.sh <频道名>              # 单个频道"
    echo "  bash scripts/export-log.sh --project <项目名>    # 项目（general + proj-xxx）"
    echo "  bash scripts/export-log.sh --all                 # 所有频道"
    echo "  bash scripts/export-log.sh <频道名> -o file.md   # 导出到文件"
    echo ""
    echo "可用频道:"
    ls "$CHANNELS_DIR" 2>/dev/null | sed 's/^/  /'
    exit 0
fi

# 生成报告
generate() {
    local ts=$(date +"%Y-%m-%d %H:%M")
    echo "# MulitBot 项目纪要"
    echo ""
    echo "导出时间: $ts"
    echo ""

    for channel in "${CHANNELS[@]}"; do
        local msgfile="$CHANNELS_DIR/$channel/messages.jsonl"
        if [ ! -f "$msgfile" ]; then
            continue
        fi

        local msg_count=$(wc -l < "$msgfile")
        local meta="$CHANNELS_DIR/$channel/meta.json"
        local created=""
        if [ -f "$meta" ]; then
            created=$(python3 -c "import json; m=json.load(open('$meta')); print(m.get('created_at','')[:10])" 2>/dev/null)
        fi

        echo "---"
        echo ""
        echo "## #$channel"
        [ -n "$created" ] && echo "创建时间: $created"
        echo "消息数: $msg_count"
        echo ""

        # 解析消息
        python3 -c "
import json, sys

prev_bot = None
for line in open('$msgfile'):
    line = line.strip()
    if not line: continue
    try:
        m = json.loads(line)
    except:
        continue

    bot = m.get('bot_id', '?')
    text = m.get('text', '')
    ts = m.get('ts', '')[:19].replace('T', ' ')
    edited = ' (已编辑)' if m.get('edited') else ''

    # 角色标签
    if bot != prev_bot:
        print(f'### [{bot}] {ts}{edited}')
        print()
    else:
        print(f'> {ts}{edited}')
        print()

    print(text)
    print()
    prev_bot = bot
" 2>/dev/null
    done

    # 性能数据
    local perf_log="$DATA_DIR/logs/hub-$(date +%Y-%m-%d).log"
    if [ -f "$perf_log" ]; then
        local perf_count=$(grep -c '"perf"' "$perf_log" 2>/dev/null || echo 0)
        if [ "$perf_count" -gt 0 ]; then
            echo "---"
            echo ""
            echo "## 性能数据"
            echo ""
            echo "| 事件 | 详情 |"
            echo "|------|------|"
            grep '"perf"' "$perf_log" | python3 -c "
import json, sys
for line in sys.stdin:
    try:
        e = json.loads(line.strip())
        ts = e.get('ts','')[:19]
        msg = e.get('msg','')
        print(f'| {ts} | {msg} |')
    except:
        pass
" 2>/dev/null
            echo ""
        fi
    fi
}

if [ -n "$OUTPUT" ]; then
    generate > "$OUTPUT"
    echo "已导出到 $OUTPUT（$(wc -l < "$OUTPUT") 行）"
else
    generate
fi
