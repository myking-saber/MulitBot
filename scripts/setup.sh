#!/bin/bash
# MulitBot 环境初始化脚本
# 创建 N 个 Bot Slot 的工作目录和共享工作区
#
# 用法:
#   bash scripts/setup.sh --slots 5           # 创建 5 个 slot
#   bash scripts/setup.sh --slots 3 --ids "lead,product,architect"  # 用指定 ID 创建

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 解析参数
SLOT_COUNT=""
SLOT_IDS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slots)
            SLOT_COUNT="$2"
            shift 2
            ;;
        --ids)
            SLOT_IDS="$2"
            shift 2
            ;;
        *)
            echo "未知参数: $1"
            echo "用法: bash scripts/setup.sh --slots <数量> [--ids \"id1,id2,...\"]"
            exit 1
            ;;
    esac
done

if [ -z "$SLOT_COUNT" ]; then
    echo "用法: bash scripts/setup.sh --slots <数量> [--ids \"id1,id2,...\"]"
    echo ""
    echo "示例:"
    echo "  bash scripts/setup.sh --slots 5                                    # 5人团队"
    echo "  bash scripts/setup.sh --slots 3 --ids \"lead,product,architect\"     # 指定 ID"
    exit 1
fi

# 将逗号分隔的 ID 列表转为数组
IFS=',' read -ra ID_ARRAY <<< "$SLOT_IDS"

echo "========================================="
echo "  MulitBot 环境初始化"
echo "========================================="
echo ""
echo "项目目录: $PROJECT_DIR"
echo "Bot 数量: $SLOT_COUNT"
echo ""

# 创建各 Slot 的工作目录
for ((i=1; i<=SLOT_COUNT; i++)); do
    # 优先用指定 ID，否则用 slot-N
    if [ -n "${ID_ARRAY[$((i-1))]}" ]; then
        bot_name="${ID_ARRAY[$((i-1))]}"
    else
        bot_name="slot-${i}"
    fi
    bot_dir="$PROJECT_DIR/bots/${bot_name}"

    echo "[Slot $i: $bot_name] 创建目录..."
    mkdir -p "$bot_dir/.claude"

    # settings.json
    if [ ! -f "$bot_dir/.claude/settings.json" ]; then
        cat > "$bot_dir/.claude/settings.json" << 'EOF'
{
  "contextCompression": {
    "triggerPercent": 30
  },
  "enabledPlugins": {
    "discord@claude-plugins-official": false,
    "claude-hud@claude-hud": false
  }
}
EOF
    fi

    echo "  → $bot_dir 已就绪"
    echo ""
done

# 创建共享工作区
mkdir -p "$PROJECT_DIR/workspace/tasks"
mkdir -p "$PROJECT_DIR/workspace/results"
mkdir -p "$PROJECT_DIR/workspace/decisions"
mkdir -p "$PROJECT_DIR/workspace/team-knowledge"

echo "========================================="
echo "  初始化完成！"
echo "========================================="
echo ""
echo "下一步："
echo "1. 招聘团队（两种方式）："
echo "   方式A（老板自动招聘）："
echo "     编辑 team.json，然后通过老板 Claude Code 自动生成角色"
echo "   方式B（逐个招聘）："
echo "     bash scripts/recruit.sh 1 true \"主持人描述\""
echo "     bash scripts/recruit.sh 2 false \"角色描述\""
echo ""
echo "2. 启动 Hub: bash scripts/hub-start.sh"
echo "3. 启动团队: bash scripts/start.sh"
