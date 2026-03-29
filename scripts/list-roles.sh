#!/bin/bash
# 列出所有可复用的角色模板
#
# 用法:
#   bash scripts/list-roles.sh              # 简洁列表
#   bash scripts/list-roles.sh --detail     # 详细信息
#   bash scripts/list-roles.sh --json       # JSON 格式（供程序解析）

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROLES_DIR="$PROJECT_DIR/roles"
MODE="${1:-brief}"

# 从 frontmatter 提取字段
extract_field() {
    local file="$1" field="$2"
    awk -v f="$field" '
    /^---$/ { fm++; next }
    fm == 1 && $0 ~ "^"f":" {
        sub("^"f":[[:space:]]*", "")
        print; exit
    }' "$file"
}

# 提取 tools
extract_tools() {
    local file="$1"
    awk '
    /^---$/ { fm++; next }
    fm == 1 && /^tools:/ {
        sub(/^tools:[[:space:]]*>-[[:space:]]*/, "")
        sub(/^tools:[[:space:]]*/, "")
        if ($0 != "") print $0
        intool=1; next
    }
    fm == 1 && intool && /^[[:space:]]/ {
        sub(/^[[:space:]]+/, "")
        if ($0 != "") print $0
        next
    }
    fm == 1 && intool { intool=0 }
    ' "$file" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# 收集所有角色（排除 _base.md）
roles=()
for f in "$ROLES_DIR"/*.md; do
    [ "$(basename "$f")" = "_base.md" ] && continue
    [ -f "$f" ] || continue
    roles+=("$f")
done

if [ ${#roles[@]} -eq 0 ]; then
    echo "暂无可复用的角色模板。" >&2
    echo "用 recruit.sh 招聘后会自动保存到 roles/ 目录。" >&2
    exit 0
fi

# 同时扫描 bots/ 中有 frontmatter 的手工角色
for f in "$PROJECT_DIR"/bots/*/CLAUDE.md; do
    [ -f "$f" ] || continue
    role_id=$(extract_field "$f" "id")
    [ -z "$role_id" ] && continue
    # 如果 roles/ 里没有对应备份，也列出来
    if [ ! -f "$ROLES_DIR/${role_id}.md" ]; then
        roles+=("$f")
    fi
done

case "$MODE" in
    --json)
        echo "["
        first=true
        for f in "${roles[@]}"; do
            id=$(extract_field "$f" "id")
            name=$(extract_field "$f" "name")
            desc=$(extract_field "$f" "description")
            mode=$(extract_field "$f" "mention_mode")
            source=$(basename "$f")
            [ "$first" = true ] && first=false || echo ","
            printf '  {"id":"%s","name":"%s","description":"%s","mention_mode":"%s","source":"%s"}' \
                "$id" "$name" "$desc" "$mode" "$source"
        done
        echo ""
        echo "]"
        ;;
    --detail)
        echo "========================================="
        echo "  可复用角色模板（共 ${#roles[@]} 个）"
        echo "========================================="
        echo ""
        for f in "${roles[@]}"; do
            id=$(extract_field "$f" "id")
            name=$(extract_field "$f" "name")
            desc=$(extract_field "$f" "description")
            mode=$(extract_field "$f" "mention_mode")
            tools=$(extract_tools "$f")
            echo "  [$id] $name"
            echo "  描述: $desc"
            echo "  模式: $mode"
            echo "  工具: $tools"
            echo "  来源: $f"
            echo ""
        done
        ;;
    *)
        echo "可复用角色（共 ${#roles[@]} 个）："
        echo ""
        for f in "${roles[@]}"; do
            id=$(extract_field "$f" "id")
            name=$(extract_field "$f" "name")
            desc=$(extract_field "$f" "description")
            printf "  %-20s %-10s %s\n" "$id" "$name" "$desc"
        done
        echo ""
        echo "复用: bash scripts/recruit.sh <slot> <is_lead> --reuse <role-id>"
        echo "详情: bash scripts/list-roles.sh --detail"
        ;;
esac
