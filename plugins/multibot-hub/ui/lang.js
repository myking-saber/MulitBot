// ======================================================================
// MulitBot Hub — i18n
// ======================================================================

const LANG = {
  'zh-CN': {
    appName: 'MulitBot',
    channels: '频道',
    projects: '项目',
    bots: '成员',
    noProjects: '暂无项目',
    inputPlaceholder: '告诉老板你想做什么...',
    send: '发送',
    enableNotif: '开启通知',
    stopProject: '中断项目',
    exportLog: '导出对话',
    waitingBoss: '等待 boss 回复...',
    processing: '正在处理...',
    confirmStop: (name) => `确定要中断项目「${name}」吗？将删除频道并通知 boss。`,
    confirmDelete: (name) => `确定删除 #${name} 吗？消息记录将被清除。`,
    deleteChannel: '删除频道',
    msgs: '条',
  },
  'en': {
    appName: 'MulitBot',
    channels: 'Channels',
    projects: 'Projects',
    bots: 'Members',
    noProjects: 'No projects yet',
    inputPlaceholder: 'Tell the boss what you need...',
    send: 'Send',
    enableNotif: 'Enable Notifications',
    stopProject: 'Stop Project',
    exportLog: 'Export Log',
    waitingBoss: 'Waiting for boss...',
    processing: 'Processing...',
    confirmStop: (name) => `Stop project "${name}"? Channel will be deleted and boss notified.`,
    confirmDelete: (name) => `Delete #${name}? All messages will be lost.`,
    deleteChannel: 'Delete channel',
    msgs: 'msgs',
  },
  'ja': {
    appName: 'MulitBot',
    channels: 'チャンネル',
    projects: 'プロジェクト',
    bots: 'メンバー',
    noProjects: 'プロジェクトなし',
    inputPlaceholder: 'ボスにやりたいことを伝えよう...',
    send: '送信',
    enableNotif: '通知を有効化',
    stopProject: 'プロジェクト中断',
    exportLog: 'ログ出力',
    waitingBoss: 'ボスの返信を待っています...',
    processing: '処理中...',
    confirmStop: (name) => `プロジェクト「${name}」を中断しますか？チャンネルは削除されます。`,
    confirmDelete: (name) => `#${name} を削除しますか？メッセージは全て失われます。`,
    deleteChannel: 'チャンネル削除',
    msgs: '件',
  },
}

// Detect language: URL param > browser > fallback
function detectLang() {
  const param = new URLSearchParams(location.search).get('lang')
  if (param && LANG[param]) return param
  const nav = navigator.language || ''
  if (nav.startsWith('zh')) return 'zh-CN'
  if (nav.startsWith('ja')) return 'ja'
  return 'en'
}

const currentLang = detectLang()
const t = LANG[currentLang] || LANG['en']
