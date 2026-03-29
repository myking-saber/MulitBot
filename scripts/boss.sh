#!/bin/bash
# 一键启动老板 Claude Code
#
# 用法:
#   bash scripts/boss.sh                           # 本机模式
#   HUB_SECRET=mykey bash scripts/boss.sh          # 公网模式（手机可访问）
#
# 老板 Claude Code 启动后，你可以直接说：
#   "帮我做一个任务管理系统"
#   "我需要3个人的团队：主持人、架构师、测试"
#   "查看团队讨论进展"

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$PROJECT_DIR/plugins/multibot-hub"
BOSS_DIR="$PROJECT_DIR/bots/boss"

export HUB_PORT="${HUB_PORT:-7800}"
export HUB_HOST="${HUB_HOST:-0.0.0.0}"
export HUB_DATA_DIR="${HUB_DATA_DIR:-$PROJECT_DIR/data}"

echo "========================================="
echo "  MulitBot — 老板模式"
echo "========================================="
echo ""
echo "启动后你可以直接说："
echo "  • \"帮我做一个XX项目\""
echo "  • \"组建团队：需要架构师和测试\""
echo "  • \"查看团队讨论\""
echo ""

# 先确保 Hub 运行
if ! bash "$PROJECT_DIR/scripts/hub-start.sh"; then
    echo "警告: Hub 启动失败，团队通信功能不可用"
    echo "你仍然可以使用老板 Claude Code，但无法与团队交互"
    echo "继续？(y/N)"
    read -r answer
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        exit 1
    fi
fi
echo ""

# 老板的工具权限（最高权限）
BOSS_TOOLS="Read,Write,Edit,Glob,Grep,WebSearch,Bash(bash scripts/*),Bash(git *),Bash(npm *),Bash(npx *),Bash(bun *),Bash(node *),Bash(python *),Bash(docker *),Bash(make *),Bash(ls *),Bash(cat *),Bash(find *),Bash(tree *),Bash(wc *),Bash(curl *),Bash(jq *),Bash(mkdir *),Bash(cp *),Bash(mv *)"

# 启动老板 Claude Code
cd "$BOSS_DIR" && \
  HUB_URL="http://127.0.0.1:${HUB_PORT}" \
  HUB_SECRET="${HUB_SECRET:-}" \
  BOT_ID="boss" \
  BOT_ROLE="老板助手" \
  MENTION_MODE="all" \
  HUB_CHANNEL="general" \
  claude \
    --plugin-dir "$PLUGIN_DIR" \
    --permission-mode acceptEdits \
    --allowedTools "$BOSS_TOOLS"
