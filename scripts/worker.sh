#!/bin/bash
# Worker 派发脚本
# 角色 Bot 调用此脚本启动临时 Claude Code 进程执行具体任务
#
# 用法: bash scripts/worker.sh <task_json_file>
# 或:   bash scripts/worker.sh --inline "<task_description>" [--workdir <dir>]
#
# 任务 JSON 格式:
# {
#   "id": "task_001",
#   "role": "architect",
#   "description": "实现背包系统的数据模型",
#   "workdir": "/path/to/project",
#   "output_format": "markdown",
#   "context_files": ["src/models/inventory.ts"]
# }

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_DIR="$PROJECT_DIR/workspace/results"
TASKS_DIR="$PROJECT_DIR/workspace/tasks"

# 生成任务 ID
generate_id() {
    echo "task_$(date +%Y%m%d_%H%M%S)_$$"
}

# 模式1: 从 JSON 文件读取任务
if [ "$1" != "--inline" ] && [ -f "$1" ]; then
    TASK_FILE="$1"
    TASK_ID=$(jq -r '.id // empty' "$TASK_FILE")
    DESCRIPTION=$(jq -r '.description' "$TASK_FILE")
    WORKDIR=$(jq -r '.workdir // "."' "$TASK_FILE")
    ROLE=$(jq -r '.role // "worker"' "$TASK_FILE")

    if [ -z "$TASK_ID" ]; then
        TASK_ID=$(generate_id)
    fi

# 模式2: 内联任务描述
elif [ "$1" == "--inline" ]; then
    shift
    DESCRIPTION="$1"
    WORKDIR="${3:-.}"
    TASK_ID=$(generate_id)
    ROLE="worker"

else
    echo "用法:"
    echo "  bash scripts/worker.sh <task.json>"
    echo "  bash scripts/worker.sh --inline \"任务描述\" [--workdir <dir>]"
    exit 1
fi

RESULT_FILE="$RESULTS_DIR/${TASK_ID}.md"

echo "[Worker] 任务 ID: $TASK_ID"
echo "[Worker] 角色: $ROLE"
echo "[Worker] 描述: $DESCRIPTION"
echo "[Worker] 工作目录: $WORKDIR"
echo "[Worker] 结果输出: $RESULT_FILE"
echo ""

# 构建 Worker 的 prompt
WORKER_PROMPT="你是一个执行者（Worker），负责完成以下具体任务。
完成后请输出结构化的结果摘要。

## 任务
$DESCRIPTION

## 要求
- 直接执行任务，不要多余讨论
- 完成后输出清晰的结果摘要
- 如果遇到问题，明确说明什么问题、卡在哪里
- 结果格式：Markdown"

# 启动临时 Claude Code 进程（使用 --print 模式，无交互）
echo "[Worker] 启动 Claude Code Worker..."
cd "$WORKDIR"

claude -p "$WORKER_PROMPT" \
    --allowedTools "Read,Write,Edit,Bash,Glob,Grep" \
    --max-turns 30 \
    > "$RESULT_FILE" 2>/dev/null

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "[Worker] 任务完成！结果已写入: $RESULT_FILE"

    # 生成摘要（取前20行作为快速预览）
    SUMMARY_FILE="$RESULTS_DIR/${TASK_ID}.summary.txt"
    head -20 "$RESULT_FILE" > "$SUMMARY_FILE"
    echo "[Worker] 摘要: $SUMMARY_FILE"
else
    echo "[Worker] 任务执行失败 (exit code: $EXIT_CODE)"
    echo "# 任务失败: $TASK_ID" > "$RESULT_FILE"
    echo "退出码: $EXIT_CODE" >> "$RESULT_FILE"
    echo "任务描述: $DESCRIPTION" >> "$RESULT_FILE"
fi

echo ""
echo "[Worker] 完成。角色 Bot 可以读取 $RESULT_FILE 获取结果。"
