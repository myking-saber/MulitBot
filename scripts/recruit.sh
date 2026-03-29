#!/bin/bash
# 动态招聘脚本 — 为指定 slot 生成或复用角色灵魂
#
# 用法:
#   bash scripts/recruit.sh <slot> <is_lead> "<soul_description>"       # 新招聘
#   bash scripts/recruit.sh <slot> <is_lead> --reuse <role-id>          # 复用已有角色
#
# 示例:
#   bash scripts/recruit.sh 1 true "沉稳的项目总监，擅长在混乱中理清头绪"
#   bash scripts/recruit.sh 2 false --reuse product                     # 复用产品经理
#   bash scripts/recruit.sh 3 false --reuse architect                   # 复用架构师
#
# 输出:
#   bots/<role-id>/CLAUDE.md — 组装好的角色定义（角色模板 + 基础规则）
#   roles/<role-id>.md       — 角色模板备份（新招聘时生成）

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROLES_DIR="$PROJECT_DIR/roles"
TEAM_FILE="$PROJECT_DIR/team.json"

# 读取语言设置
LANG_CODE=$(jq -r '.lang // "zh-CN"' "$TEAM_FILE" 2>/dev/null || echo "zh-CN")
# 语言映射：zh-CN → zh-CN, en → en, 其他 → en
case "$LANG_CODE" in
    zh*) LANG_KEY="zh-CN" ;;
    ja*) LANG_KEY="ja" ;;
    *) LANG_KEY="en" ;;
esac

# 选择对应语言的 _base.md
if [ -f "$ROLES_DIR/i18n/_base.${LANG_KEY}.md" ]; then
    BASE_TEMPLATE="$ROLES_DIR/i18n/_base.${LANG_KEY}.md"
else
    BASE_TEMPLATE="$ROLES_DIR/_base.md"
fi

# 参数检查
SLOT="${1:?用法: bash scripts/recruit.sh <slot> <is_lead> \"描述\" 或 --reuse <role-id>}"
IS_LEAD="${2:?缺少 is_lead 参数 (true/false)}"
shift 2

# 判断模式：--reuse 还是新招聘
REUSE_ID=""
SOUL_DESC=""

if [ "$1" = "--reuse" ]; then
    REUSE_ID="${2:?--reuse 需要指定 role-id}"
else
    SOUL_DESC="${1:?缺少角色描述或 --reuse 参数}"
fi

if [ ! -f "$BASE_TEMPLATE" ]; then
    echo "错误: 找不到 $BASE_TEMPLATE" >&2
    exit 1
fi

# ============================================================
# 复用模式
# ============================================================
if [ -n "$REUSE_ID" ]; then
    echo "[recruit] Slot $SLOT | 复用角色: $REUSE_ID" >&2

    # 查找角色模板：先 roles/，再 bots/
    TEMPLATE_FILE=""
    if [ -f "$ROLES_DIR/${REUSE_ID}.md" ]; then
        TEMPLATE_FILE="$ROLES_DIR/${REUSE_ID}.md"
    elif [ -f "$PROJECT_DIR/bots/${REUSE_ID}/CLAUDE.md" ]; then
        TEMPLATE_FILE="$PROJECT_DIR/bots/${REUSE_ID}/CLAUDE.md"
    else
        echo "错误: 找不到角色 '$REUSE_ID'" >&2
        echo "可用角色: $(ls "$ROLES_DIR"/*.md 2>/dev/null | xargs -I{} basename {} .md | grep -v _base | tr '\n' ' ')" >&2
        exit 1
    fi

    ROLE_ID="$REUSE_ID"
    # 读取模板内容（如果来自 bots/ 目录，需要去掉 _base.md 部分）
    if [[ "$TEMPLATE_FILE" == */bots/*/CLAUDE.md ]]; then
        # bots/CLAUDE.md = 角色定义 + --- + _base.md，只取角色定义部分
        ROLE_CONTENT=$(awk '/^---$/ && seen++ {exit} {print}' "$TEMPLATE_FILE")
    else
        ROLE_CONTENT=$(cat "$TEMPLATE_FILE")
    fi

    echo "[recruit] 来源: $TEMPLATE_FILE" >&2

    # 创建 bot 目录
    BOT_DIR="$PROJECT_DIR/bots/${ROLE_ID}"
    mkdir -p "$BOT_DIR/.claude"
    cat > "$BOT_DIR/.claude/settings.json" << 'EOF'
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

    # 组装最终 CLAUDE.md = 角色定义 + 基础规则 + 历史经验
    EXPERIENCE_FILE="$ROLES_DIR/${ROLE_ID}.experience.md"
    {
        echo "$ROLE_CONTENT"
        echo ""
        echo "---"
        echo ""
        cat "$BASE_TEMPLATE"
        # 如果有历史经验，追加到末尾
        if [ -f "$EXPERIENCE_FILE" ]; then
            echo ""
            echo "---"
            echo ""
            echo "## 历史经验"
            echo ""
            echo "以下是你在之前项目中积累的经验，请认真阅读并应用："
            echo ""
            cat "$EXPERIENCE_FILE"
        fi
    } > "$BOT_DIR/CLAUDE.md"

    if [ -f "$EXPERIENCE_FILE" ]; then
        exp_count=$(grep -c "^## " "$EXPERIENCE_FILE" 2>/dev/null || echo 0)
        echo "[recruit] 📚 载入 ${exp_count} 条历史经验" >&2
    fi
    echo "[recruit] ✅ 复用完成" >&2
    echo "[recruit] 角色: $ROLE_ID" >&2
    echo "[recruit] 灵魂: bots/${ROLE_ID}/CLAUDE.md" >&2
    echo "{\"slot\":${SLOT},\"role_id\":\"${ROLE_ID}\",\"is_lead\":${IS_LEAD},\"reused\":true}"
    exit 0
fi

# ============================================================
# 新招聘模式
# ============================================================
if ! command -v claude &> /dev/null; then
    echo "错误: 需要安装 claude CLI" >&2
    exit 1
fi

echo "[recruit] Slot $SLOT | Lead=$IS_LEAD" >&2
echo "[recruit] Soul: $SOUL_DESC" >&2

# Lead 专属规则
if [ "$IS_LEAD" = "true" ]; then
    LEAD_EXTRA="
这个角色是团队的 Lead（主持人/协调者）。额外规则：
- Lead 是主协调者，负责拆解需求、分发问题、收集意见（fetch_messages）、综合决策
- Lead 可以 @mention 任何角色分配任务和提问
- Lead 将决策写入 workspace/decisions/
- Lead 不亲自执行大任务，通过 worker.sh 派发
- mention_mode 设为 all（接收频道内所有消息）"
else
    LEAD_EXTRA="
这个角色不是 Lead。额外规则：
- 可以 @mention 同项目的其他角色（用 @角色id 格式），用于技术讨论和信息确认
- 和同一角色来回超过 3 轮未解决，必须 @lead 让主持人介入
- 完成讨论后 @lead 汇报结论
- 被 @mention 时必须响应
- mention_mode 设为 mention（只收到 @自己 的消息）"
fi

# 语言指令
if [ "$LANG_KEY" = "zh-CN" ]; then
    LANG_INST="用中文输出所有内容。name 字段用中文。"
    NAME_HINT="中文角色名"
elif [ "$LANG_KEY" = "ja" ]; then
    LANG_INST="日本語で全ての内容を出力してください。name フィールドは日本語で。"
    NAME_HINT="日本語の役割名"
else
    LANG_INST="Output everything in English. name field in English."
    NAME_HINT="English role name"
fi

# 生成 prompt
PROMPT="You are a role designer. Generate a complete role definition file for an AI collaboration team based on the boss's description.

**Language: ${LANG_INST}**

## Boss's Description
${SOUL_DESC}

${LEAD_EXTRA}

## Output Format

Output a Markdown file with YAML frontmatter + body. Output content only, no explanations.

frontmatter format:
---
name: {${NAME_HINT}}
id: {lowercase English ID, hyphen-separated, e.g. backend-engineer}
description: {one-line role description, in the target language}
mention_mode: {all 或 mention}
tools: >-
  {Claude Code 工具权限，逗号分隔，一行写完}
  可选工具: Read, Write, Edit, Glob, Grep, WebSearch
  Bash 权限格式: Bash(command pattern*)
  所有角色必须有: Bash(bash scripts/worker.sh*),Bash(ls *),Bash(cat *),Bash(find *),Bash(tree *)
  技术角色加: Bash(git *) 和对应构建/运行/测试工具
  非技术角色不需要 Write/Edit 代码，但可以 Write(workspace/*)
---

正文必须包含这些章节：

# 角色：{名称}

## 身份
{2-3句话，这个角色是谁、核心价值}

## 决策框架
{3-4 条评估维度，按优先级排列，每条一句话}
{框架要能产生真正的分歧和讨论价值}

## 性格特质
{4 条鲜明的性格，不要泛泛的好人描述}
{要能指导实际行为}

## 核心职责
{5-6 条}

## 你掌握的工具
{自然语言描述能用什么、怎么用}

## 回复风格
{给出结构化回复模板，用代码块}

## 个体记忆重点
{4-5 条该角色应该记住的经验类型}"

# 调用 Claude 生成
ROLE_CONTENT=$(claude -p "$PROMPT" --allowedTools "" --max-turns 1 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$ROLE_CONTENT" ]; then
    echo "[recruit] ❌ 生成失败" >&2
    exit 1
fi

# 提取 role ID
ROLE_ID=$(echo "$ROLE_CONTENT" | grep "^id:" | head -1 | sed 's/id:[[:space:]]*//')
if [ -z "$ROLE_ID" ]; then
    ROLE_ID="slot-${SLOT}-role"
fi

# 使用 role ID 作为目录名
BOT_DIR="$PROJECT_DIR/bots/${ROLE_ID}"
mkdir -p "$BOT_DIR/.claude"
cat > "$BOT_DIR/.claude/settings.json" << 'EOF'
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

# 保存角色模板到 roles/
echo "$ROLE_CONTENT" > "$ROLES_DIR/${ROLE_ID}.md"

# 组装最终 CLAUDE.md = 角色定义 + 基础规则 + 历史经验
EXPERIENCE_FILE="$ROLES_DIR/${ROLE_ID}.experience.md"
{
    echo "$ROLE_CONTENT"
    echo ""
    echo "---"
    echo ""
    cat "$BASE_TEMPLATE"
    if [ -f "$EXPERIENCE_FILE" ]; then
        echo ""
        echo "---"
        echo ""
        echo "## 历史经验"
        echo ""
        echo "以下是你在之前项目中积累的经验，请认真阅读并应用："
        echo ""
        cat "$EXPERIENCE_FILE"
    fi
} > "$BOT_DIR/CLAUDE.md"

if [ -f "$EXPERIENCE_FILE" ]; then
    exp_count=$(grep -c "^## " "$EXPERIENCE_FILE" 2>/dev/null || echo 0)
    echo "[recruit] 📚 载入 ${exp_count} 条历史经验" >&2
fi
echo "[recruit] ✅ 完成" >&2
echo "[recruit] 角色: $ROLE_ID" >&2
echo "[recruit] 模板: roles/${ROLE_ID}.md" >&2
echo "[recruit] 灵魂: bots/${ROLE_ID}/CLAUDE.md" >&2

# 输出 JSON 格式的结果（供调用方解析）
echo "{\"slot\":${SLOT},\"role_id\":\"${ROLE_ID}\",\"is_lead\":${IS_LEAD},\"reused\":false}"
