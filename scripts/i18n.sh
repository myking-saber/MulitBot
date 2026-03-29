#!/bin/bash
# MulitBot — 脚本多语言支持
# source 此文件后使用 $L_xxx 变量

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TEAM_FILE="${TEAM_FILE:-$PROJECT_DIR/team.json}"

# 读取语言：team.json > 系统语言 > 默认 en
if [ -f "$TEAM_FILE" ] && command -v jq &>/dev/null; then
    _LANG=$(jq -r '.lang // ""' "$TEAM_FILE" 2>/dev/null)
fi
if [ -z "$_LANG" ]; then
    case "${LANG:-${LC_ALL:-en}}" in
        zh*) _LANG="zh-CN" ;;
        ja*) _LANG="ja" ;;
        *) _LANG="en" ;;
    esac
fi

case "$_LANG" in
    zh*)
        L_STARTING="启动中"
        L_STARTED="已启动"
        L_STOPPED="已停止"
        L_STOPPING="停止中"
        L_HUB_STARTING="启动 Hub..."
        L_HUB_RUNNING="Hub 已在运行"
        L_HUB_READY="Hub 就绪"
        L_HUB_TIMEOUT="Hub 启动超时"
        L_BOT_STARTING="启动 Bot..."
        L_BOT_BOSS="Boss（老板助手）"
        L_BOT_ONDEMAND="团队成员将由 Boss 按需启动"
        L_WAITING_INIT="等待 Boss 初始化..."
        L_MONITOR_STARTED="Monitor 已启动"
        L_TEAM_STARTED="系统已启动！"
        L_ALL_STOPPED="所有进程已停止。"
        L_CLOSING="关闭"
        L_SESSION_KILLED="会话已强制关闭"
        L_NO_SESSION="没有运行中的 MulitBot 会话。"
        L_PHONE="手机"
        L_MANAGE="管理"
        L_STOP_CMD="停止"
        L_ERR_MISSING="错误: 找不到"
        L_ERR_NEED="错误: 需要安装"
        L_ERR_NO_SLOTS="错误: team.json 缺少 slots 字段"
        L_ERR_NO_HUB="错误: team.json 缺少 hub 配置"
        L_AUTO_FIX="正在自动修复..."
        L_HUB_FIX_DONE="已添加默认 hub 配置"
        L_POLL_INTERVAL="轮询间隔"
        ;;
    ja*)
        L_STARTING="起動中"
        L_STARTED="起動完了"
        L_STOPPED="停止済み"
        L_STOPPING="停止中"
        L_HUB_STARTING="Hub を起動中..."
        L_HUB_RUNNING="Hub は既に起動中"
        L_HUB_READY="Hub 準備完了"
        L_HUB_TIMEOUT="Hub 起動タイムアウト"
        L_BOT_STARTING="Bot を起動中..."
        L_BOT_BOSS="Boss（マネージャー）"
        L_BOT_ONDEMAND="チームメンバーは Boss が必要に応じて起動します"
        L_WAITING_INIT="Boss の初期化を待機中..."
        L_MONITOR_STARTED="Monitor 起動完了"
        L_TEAM_STARTED="システム起動完了！"
        L_ALL_STOPPED="全プロセス停止済み。"
        L_CLOSING="終了中"
        L_SESSION_KILLED="セッション強制終了"
        L_NO_SESSION="実行中の MulitBot セッションはありません。"
        L_PHONE="モバイル"
        L_MANAGE="管理"
        L_STOP_CMD="停止"
        L_ERR_MISSING="エラー: 見つかりません"
        L_ERR_NEED="エラー: インストールが必要"
        L_ERR_NO_SLOTS="エラー: team.json に slots がありません"
        L_ERR_NO_HUB="エラー: team.json に hub 設定がありません"
        L_AUTO_FIX="自動修復中..."
        L_HUB_FIX_DONE="デフォルト hub 設定を追加しました"
        L_POLL_INTERVAL="ポーリング間隔"
        ;;
    *)
        L_STARTING="Starting"
        L_STARTED="Started"
        L_STOPPED="Stopped"
        L_STOPPING="Stopping"
        L_HUB_STARTING="Starting Hub..."
        L_HUB_RUNNING="Hub already running"
        L_HUB_READY="Hub ready"
        L_HUB_TIMEOUT="Hub startup timeout"
        L_BOT_STARTING="Starting Bots..."
        L_BOT_BOSS="Boss (Manager)"
        L_BOT_ONDEMAND="Team members will be started on demand by Boss"
        L_WAITING_INIT="Waiting for Boss to initialize..."
        L_MONITOR_STARTED="Monitor started"
        L_TEAM_STARTED="System started!"
        L_ALL_STOPPED="All processes stopped."
        L_CLOSING="Closing"
        L_SESSION_KILLED="Session force-killed"
        L_NO_SESSION="No running MulitBot session."
        L_PHONE="Phone"
        L_MANAGE="Manage"
        L_STOP_CMD="Stop"
        L_ERR_MISSING="Error: not found"
        L_ERR_NEED="Error: need to install"
        L_ERR_NO_SLOTS="Error: team.json missing slots"
        L_ERR_NO_HUB="Error: team.json missing hub config"
        L_AUTO_FIX="Auto-fixing..."
        L_HUB_FIX_DONE="Added default hub config"
        L_POLL_INTERVAL="Poll interval"
        ;;
esac
