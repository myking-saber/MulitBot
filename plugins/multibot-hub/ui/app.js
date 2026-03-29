// ======================================================================
// MulitBot Hub — Client-side app
// ======================================================================

const BOT_ID = 'client'

// --- Notification system ---
let unreadCount = 0
let audioCtx = null

function playNotifSound() {
  try {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)()
    const osc = audioCtx.createOscillator()
    const gain = audioCtx.createGain()
    osc.connect(gain)
    gain.connect(audioCtx.destination)
    osc.frequency.value = 800
    gain.gain.value = 0.3
    osc.start()
    gain.gain.exponentialRampToValueAtTime(0.001, audioCtx.currentTime + 0.3)
    osc.stop(audioCtx.currentTime + 0.3)
  } catch {}
}

function notify(title, body) {
  // Sound + vibrate
  playNotifSound()
  if (navigator.vibrate) navigator.vibrate(200)

  // Badge in title
  if (!document.hasFocus()) {
    unreadCount++
    document.title = `(${unreadCount}) MulitBot Hub`
  }

  // Browser notification
  if (Notification.permission === 'granted') {
    new Notification(title, { body: body.slice(0, 100), icon: '/favicon.ico' })
  }
}

function enableNotifications() {
  if ('Notification' in window && Notification.permission === 'default') {
    Notification.requestPermission()
  }
  // Also resume AudioContext (iOS/Chrome policy)
  if (audioCtx && audioCtx.state === 'suspended') audioCtx.resume()
}

window.addEventListener('focus', () => {
  unreadCount = 0
  document.title = 'MulitBot Hub'
})

// Bot color palette
const COLORS = [
  '#e94560', '#53c1de', '#4caf50', '#ff9800', '#9c27b0',
  '#00bcd4', '#ff5722', '#3f51b5', '#8bc34a', '#f44336',
]
const botColors = {}
function getBotColor(botId) {
  if (!botColors[botId]) {
    const idx = Object.keys(botColors).length % COLORS.length
    botColors[botId] = COLORS[idx]
  }
  return botColors[botId]
}

// State
let currentChannel = 'general'
let ws = null
let knownBots = []
let botStatus = {} // bot_id → { online, busy_since }
let reconnectTimer = null
let waitingForReply = false
const messageCache = {} // channel → messages[]

// --- Cookie helper ---
function getCookie(name) {
  const m = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'))
  return m ? m[2] : null
}

function getSecret() {
  // Try cookie first, then URL param
  return getCookie('hub_secret') || new URLSearchParams(location.search).get('secret') || ''
}

// --- API helpers ---
async function api(method, path, body) {
  const secret = getSecret()
  const headers = { 'X-Bot-Id': BOT_ID }
  if (secret) headers['Authorization'] = 'Bearer ' + secret
  if (body) headers['Content-Type'] = 'application/json'
  const res = await fetch('/api' + path, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) throw new Error(await res.text())
  return res.json()
}

// --- WebSocket ---
function connectWS() {
  const statusDot = document.getElementById('connection-status')
  statusDot.className = 'status-dot connecting'

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:'
  const secret = getSecret()
  ws = new WebSocket(`${proto}//${location.host}/ws`)

  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'auth', bot_id: BOT_ID, secret }))
  }

  ws.onmessage = (e) => {
    const frame = JSON.parse(e.data)

    if (frame.type === 'auth_ok') {
      statusDot.className = 'status-dot connected'
      knownBots = frame.bots || []
      renderBotList()
    }

    if (frame.type === 'auth_fail') {
      statusDot.className = 'status-dot disconnected'
      location.href = '/login'
    }

    if (frame.type === 'message') {
      const msg = frame.data
      if (!messageCache[msg.channel]) messageCache[msg.channel] = []
      messageCache[msg.channel].push(msg)
      if (msg.channel === currentChannel) {
        appendMessage(msg)
        scrollToBottom()
      }
      // Clear waiting indicator when boss replies in general
      if (msg.bot_id === 'boss' && msg.channel === 'general' && waitingForReply) {
        hideWaiting()
      }
      // Clear typing indicator when any bot sends a message
      const typingEl = document.getElementById('typing-indicator')
      if (typingEl) typingEl.remove()
      // Notify client if @client or project done
      if (msg.bot_id !== BOT_ID) {
        const isMentioned = msg.mentions && msg.mentions.includes(BOT_ID)
        const isDone = /完成|已完成|验收通过|交付|done|complete/i.test(msg.text)
        if (isMentioned || isDone) {
          notify(`${msg.bot_id}`, msg.text)
        }
        // Update unread badge on channel tabs
        if (msg.channel !== currentChannel) {
          const tab = document.querySelector(`.ch-tab[data-channel="${msg.channel}"]`)
          if (tab && !tab.querySelector('.unread-dot')) {
            const dot = document.createElement('span')
            dot.className = 'unread-dot'
            tab.appendChild(dot)
          }
        }
      }
      // Update channel list
      loadChannels()
      // Track new bots
      if (!knownBots.includes(msg.bot_id)) {
        knownBots.push(msg.bot_id)
        renderBotList()
      }
      // Update bot status
      botStatus[msg.bot_id] = { online: true, busy_since: null }
      renderBotList()
    }

    if (frame.type === 'bot_typing') {
      // Show typing indicator
      const d = frame.data
      botStatus[d.bot_id] = { online: true, busy_since: Date.now() }
      renderBotList()
      showTyping(d.bot_id)
    }

    if (frame.type === 'reaction') {
      // Re-render affected message
      const msgEl = document.querySelector(`[data-id="${frame.data.message_id}"] .msg-reactions`)
      if (msgEl) {
        // Reload messages for simplicity
        loadMessages(currentChannel)
      }
    }

    if (frame.type === 'channel_created') {
      loadChannels()
      loadProjects()
    }

    if (frame.type === 'channel_deleted') {
      if (currentChannel === frame.data.name) switchChannel('general')
      loadChannels()
      loadProjects()
    }

    if (frame.type === 'bot_joined') {
      if (!knownBots.includes(frame.bot_id)) {
        knownBots.push(frame.bot_id)
        renderBotList()
      }
    }
  }

  ws.onclose = () => {
    statusDot.className = 'status-dot disconnected'
    reconnectTimer = setTimeout(connectWS, 3000)
  }

  ws.onerror = () => {
    ws.close()
  }
}

// --- Render ---

function renderMessage(msg, continued) {
  const div = document.createElement('div')
  div.className = 'msg' + (continued ? ' continued' : '')
  div.dataset.id = msg.id

  const color = getBotColor(msg.bot_id)
  const initial = msg.bot_id.charAt(0).toUpperCase()
  const time = new Date(msg.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })

  // Highlight @mentions in text
  const htmlText = escapeHtml(msg.text).replace(
    /@([\w][\w-]*)/g,
    '<span class="mention">@$1</span>'
  )

  // Reactions
  let reactionsHtml = ''
  if (msg.reactions && Object.keys(msg.reactions).length > 0) {
    reactionsHtml = '<div class="msg-reactions">'
    for (const [emoji, bots] of Object.entries(msg.reactions)) {
      reactionsHtml += `<span class="msg-reaction" data-emoji="${emoji}" data-msg="${msg.id}">${emoji} ${bots.length}</span>`
    }
    reactionsHtml += '</div>'
  }

  div.innerHTML = `
    <div class="msg-avatar" style="background:${color}">${initial}</div>
    <div class="msg-body">
      <div class="msg-header">
        <span class="msg-author" style="color:${color}">${escapeHtml(msg.bot_id)}</span>
        <span class="msg-time">${time}</span>
      </div>
      <div class="msg-text">${htmlText}</div>
      ${reactionsHtml}
    </div>
  `
  return div
}

function appendMessage(msg) {
  const container = document.getElementById('messages')
  const children = container.children
  let continued = false
  if (children.length > 0) {
    const lastEl = children[children.length - 1]
    const lastAuthor = lastEl.querySelector('.msg-author')
    if (lastAuthor && lastAuthor.textContent === msg.bot_id) {
      const lastTimeEl = lastEl.querySelector('.msg-time')
      if (lastTimeEl) {
        // 同一作者 2 分钟内的消息合并显示
        const lastTime = lastEl.dataset.ts ? new Date(lastEl.dataset.ts) : null
        const msgTime = new Date(msg.ts)
        if (lastTime && (msgTime - lastTime) < 120000) {
          continued = true
        }
      }
    }
  }
  const el = renderMessage(msg, continued)
  el.dataset.ts = msg.ts
  container.appendChild(el)
}

function renderMessages(messages) {
  const container = document.getElementById('messages')
  container.innerHTML = ''
  let lastBotId = null
  for (const msg of messages) {
    const continued = msg.bot_id === lastBotId
    container.appendChild(renderMessage(msg, continued))
    lastBotId = msg.bot_id
  }
  scrollToBottom()
}

function renderChannelList(channels) {
  const ul = document.getElementById('channel-list')
  ul.innerHTML = ''
  for (const ch of channels) {
    const li = document.createElement('li')
    li.className = ch.name === currentChannel ? 'active' : ''
    li.innerHTML = `<span class="ch-hash">#</span> ${escapeHtml(ch.name)}`
    li.onclick = () => switchChannel(ch.name)
    // Delete button (not for #general)
    if (ch.name !== 'general') {
      const del = document.createElement('button')
      del.className = 'ch-delete'
      del.innerHTML = '&times;'
      del.title = t.deleteChannel
      del.onclick = (e) => { e.stopPropagation(); deleteChannel(ch.name) }
      li.appendChild(del)
    }
    ul.appendChild(li)
  }
}

async function deleteChannel(name) {
  if (!confirm(t.confirmDelete(name))) return
  try {
    await api('DELETE', `/channels/${encodeURIComponent(name)}`)
    if (currentChannel === name) switchChannel('general')
    await loadChannels()
    loadProjects()
  } catch (e) {
    console.error('delete channel failed:', e)
  }
}

function renderBotList() {
  const ul = document.getElementById('bot-list')
  ul.innerHTML = ''
  for (const botId of knownBots) {
    const li = document.createElement('li')
    const color = getBotColor(botId)
    const status = botStatus[botId]
    const isBusy = status && status.busy_since && (Date.now() - status.busy_since < 120000)
    const statusText = isBusy ? `<span class="bot-status busy">${t.processing}</span>` : ''
    li.innerHTML = `<span class="bot-dot" style="background:${color}"></span> ${escapeHtml(botId)} ${statusText}`
    ul.appendChild(li)
  }
}

// --- Actions ---

function renderChannelTabs(channels) {
  const container = document.getElementById('channel-tabs')
  container.innerHTML = ''
  for (const ch of channels) {
    const tab = document.createElement('button')
    tab.className = 'ch-tab' + (ch.name === currentChannel ? ' active' : '')
    tab.dataset.channel = ch.name
    tab.textContent = '#' + ch.name
    tab.onclick = () => switchChannel(ch.name)
    container.appendChild(tab)
  }
}

async function loadChannels() {
  try {
    const channels = await api('GET', '/channels')
    renderChannelList(channels)
    renderChannelTabs(channels)
  } catch {}
}

async function loadProjects() {
  try {
    const projects = await api('GET', '/projects')
    const ul = document.getElementById('project-list')
    ul.innerHTML = ''
    if (projects.length === 0) {
      ul.innerHTML = `<li style="color:var(--text-secondary);font-size:13px">${t.noProjects}</li>`
      return
    }
    for (const p of projects) {
      const li = document.createElement('li')
      li.innerHTML = `<span class="proj-dot"></span> ${escapeHtml(p.name)} <span style="color:var(--text-secondary);font-size:12px;margin-left:auto">${p.message_count} ${t.msgs}</span>`
      li.onclick = () => switchChannel(p.channel)
      ul.appendChild(li)
    }
  } catch {}
}

async function loadMessages(channel) {
  try {
    const messages = await api('GET', `/messages/${encodeURIComponent(channel)}?limit=50`)
    messageCache[channel] = messages
    renderMessages(messages)
  } catch (e) {
    console.error('load messages failed:', e)
  }
}

function switchChannel(name) {
  currentChannel = name
  document.getElementById('channel-name').textContent = '#' + name
  document.querySelectorAll('#channel-list li').forEach(li => {
    li.className = li.textContent.trim().slice(1).trim() === name ? 'active' : ''
  })
  document.querySelectorAll('.ch-tab').forEach(tab => {
    const isActive = tab.dataset.channel === name
    tab.className = 'ch-tab' + (isActive ? ' active' : '')
    if (isActive) {
      const dot = tab.querySelector('.unread-dot')
      if (dot) dot.remove()
    }
  })
  // 项目频道显示中断按钮
  const stopBtn = document.getElementById('stop-btn')
  if (name.startsWith('proj-')) {
    stopBtn.classList.remove('hidden')
  } else {
    stopBtn.classList.add('hidden')
  }
  // 清空缓存，强制重新拉取
  delete messageCache[name]
  document.getElementById('messages').innerHTML = ''
  // 清除 waiting/typing 指示器
  const w = document.getElementById('waiting-indicator')
  if (w) w.remove()
  const t = document.getElementById('typing-indicator')
  if (t) t.remove()
  loadMessages(name)
  closeSidebar()
}

function scrollToBottom() {
  const el = document.getElementById('messages')
  requestAnimationFrame(() => { el.scrollTop = el.scrollHeight })
}

// --- Waiting / typing indicators ---

function showWaiting() {
  waitingForReply = true
  let el = document.getElementById('waiting-indicator')
  if (!el) {
    el = document.createElement('div')
    el.id = 'waiting-indicator'
    el.className = 'waiting-bar'
    document.getElementById('messages').appendChild(el)
  }
  el.innerHTML = `<span class="waiting-dots"></span> ${t.waitingBoss}`
  scrollToBottom()
}

function hideWaiting() {
  waitingForReply = false
  const el = document.getElementById('waiting-indicator')
  if (el) el.remove()
}

function showTyping(botId) {
  let el = document.getElementById('typing-indicator')
  if (!el) {
    el = document.createElement('div')
    el.id = 'typing-indicator'
    el.className = 'typing-bar'
    document.getElementById('messages').appendChild(el)
  }
  const color = getBotColor(botId)
  el.innerHTML = `<span class="msg-avatar" style="background:${color};width:24px;height:24px;font-size:11px">${botId.charAt(0).toUpperCase()}</span> <span class="waiting-dots"></span> ${escapeHtml(botId)} ${t.processing}`
  scrollToBottom()
  // Auto-hide after 60s
  clearTimeout(el._timer)
  el._timer = setTimeout(() => { if (el.parentNode) el.remove() }, 60000)
}

function escapeHtml(s) {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}

// --- Sidebar ---

function openSidebar() {
  document.getElementById('sidebar').classList.remove('hidden')
  let overlay = document.getElementById('sidebar-overlay')
  if (!overlay) {
    overlay = document.createElement('div')
    overlay.id = 'sidebar-overlay'
    overlay.onclick = closeSidebar
    document.getElementById('app').appendChild(overlay)
  }
  overlay.classList.add('visible')
}

function closeSidebar() {
  document.getElementById('sidebar').classList.add('hidden')
  const overlay = document.getElementById('sidebar-overlay')
  if (overlay) overlay.classList.remove('visible')
}

// --- @mention autocomplete ---

function setupMentionPopup() {
  const input = document.getElementById('msg-input')
  const popup = document.getElementById('mention-popup')
  let mentionStart = -1

  input.addEventListener('input', () => {
    const val = input.value
    const cursor = input.selectionStart
    // Find @ before cursor
    const before = val.slice(0, cursor)
    const atIdx = before.lastIndexOf('@')
    if (atIdx >= 0 && (atIdx === 0 || before[atIdx - 1] === ' ')) {
      const query = before.slice(atIdx + 1).toLowerCase()
      const matches = knownBots.filter(b => b.toLowerCase().startsWith(query))
      if (matches.length > 0 && query.length >= 0) {
        mentionStart = atIdx
        popup.innerHTML = ''
        popup.classList.remove('hidden')
        for (const bot of matches) {
          const item = document.createElement('div')
          item.className = 'mention-item'
          item.innerHTML = `<span class="bot-dot" style="background:${getBotColor(bot)}"></span> ${escapeHtml(bot)}`
          item.onclick = () => {
            input.value = val.slice(0, mentionStart) + '@' + bot + ' ' + val.slice(cursor)
            popup.classList.add('hidden')
            input.focus()
          }
          popup.appendChild(item)
        }
        return
      }
    }
    popup.classList.add('hidden')
  })

  input.addEventListener('blur', () => {
    setTimeout(() => popup.classList.add('hidden'), 200)
  })
}

// --- Export channel log ---

function exportChannel() {
  const secret = getSecret()
  const authParam = secret ? `?secret=${secret}` : ''
  window.open(`/api/export/${encodeURIComponent(currentChannel)}${authParam}`, '_blank')
}

// --- Stop project ---

let stopInProgress = false
async function stopProject() {
  if (!currentChannel.startsWith('proj-')) return
  if (stopInProgress) return
  const projName = currentChannel.replace('proj-', '')
  if (!confirm(t.confirmStop(projName))) return
  stopInProgress = true
  const btn = document.getElementById('stop-btn')
  btn.textContent = '...'
  btn.disabled = true
  try {
    // 先通知 boss
    await api('POST', '/messages', {
      channel: 'general',
      text: `@boss 客户已中断项目「${projName}」，#${currentChannel} 频道将被删除。请停止该项目的所有团队工作。`
    })
    // 删除项目频道
    await api('DELETE', `/channels/${encodeURIComponent(currentChannel)}`)
    // 切回 general
    switchChannel('general')
  } catch (e) {
    console.error('stop project failed:', e)
  } finally {
    stopInProgress = false
    btn.textContent = '■'
    btn.disabled = false
  }
}

// --- Send message ---

async function sendMessage() {
  const input = document.getElementById('msg-input')
  const text = input.value.trim()
  if (!text) return
  input.value = ''
  try {
    await api('POST', '/messages', { channel: currentChannel, text })
    // Show waiting indicator in #general (waiting for boss)
    if (currentChannel === 'general') {
      showWaiting()
    }
  } catch (e) {
    console.error('send failed:', e)
    input.value = text // restore on failure
  }
}

// --- Init ---

// Apply i18n labels
document.getElementById('lbl-channels').textContent = t.channels
document.getElementById('lbl-projects').textContent = t.projects
document.getElementById('lbl-bots').textContent = t.bots
document.getElementById('msg-input').placeholder = t.inputPlaceholder
document.getElementById('send-btn').textContent = t.send
document.getElementById('export-btn').title = t.exportLog
document.getElementById('stop-btn').title = t.stopProject
document.getElementById('notif-btn').title = t.enableNotif
document.documentElement.lang = currentLang
document.title = t.appName + ' Hub'

document.getElementById('menu-btn').onclick = openSidebar
document.getElementById('close-sidebar').onclick = closeSidebar
document.getElementById('send-btn').onclick = sendMessage
document.getElementById('msg-input').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault()
    sendMessage()
  }
})
setupMentionPopup()
loadChannels()
loadProjects()
loadMessages(currentChannel)
connectWS()
