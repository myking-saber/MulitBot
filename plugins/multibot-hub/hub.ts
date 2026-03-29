#!/usr/bin/env bun
// ======================================================================
// MulitBot Hub — Self-hosted message server
//
// Single process: HTTP API + WebSocket + Static Web UI
// Designed for both local and public network access.
//
// Env vars:
//   HUB_PORT     — Listen port (default 7800)
//   HUB_HOST     — Bind address (default 0.0.0.0)
//   HUB_SECRET   — Auth secret (required for non-localhost)
//   HUB_DATA_DIR — Data directory (default ./data)
//   HUB_TUNNEL   — "cloudflared" to auto-start tunnel (optional)
// ======================================================================

import { readFileSync, existsSync, writeFileSync, statSync, appendFileSync, mkdirSync } from 'fs'
import { join, extname, resolve } from 'path'
import { Storage } from './storage'
import type { HubMessage, WSClientFrame, WSServerFrame, SendMessageBody, ReactBody, CreateChannelBody } from './types'

const PORT = parseInt(process.env.HUB_PORT || '7800')
const HOST = process.env.HUB_HOST || '0.0.0.0'
const SECRET = process.env.HUB_SECRET || ''
const DATA_DIR = process.env.HUB_DATA_DIR || join(import.meta.dir, '..', '..', 'data')
const TUNNEL = process.env.HUB_TUNNEL || ''

const storage = new Storage(DATA_DIR)
storage.createChannel('general') // 确保 #general 始终存在

// ======================================================================
// Logging
// ======================================================================

const LOG_DIR = join(DATA_DIR, 'logs')
mkdirSync(LOG_DIR, { recursive: true })

function hubLog(level: 'INFO' | 'WARN' | 'ERROR', category: string, msg: string, extra?: Record<string, unknown>) {
  const ts = new Date().toISOString()
  const line = JSON.stringify({ ts, level, cat: category, msg, ...extra })
  const date = ts.slice(0, 10)
  try {
    appendFileSync(join(LOG_DIR, `hub-${date}.log`), line + '\n')
  } catch {}
  if (level === 'ERROR') process.stderr.write(`[${ts}] ERROR ${category}: ${msg}\n`)
}

// ======================================================================
// Performance Tracking — 响应时间 + 任务耗时
// ======================================================================

// 追踪 @mention 的发起时间：{ "bot_id:channel" → timestamp }
const mentionTracker = new Map<string, number>()
// 追踪任务开始时间：{ "bot_id" → { start, channel, task } }
const taskTracker = new Map<string, { start: number; channel: string; task: string }>()

function trackMentions(msg: HubMessage) {
  const now = Date.now()
  // 记录被 @mention 的 bot 的等待起始时间
  for (const mentioned of msg.mentions) {
    const key = `${mentioned}:${msg.channel}`
    if (!mentionTracker.has(key)) {
      mentionTracker.set(key, now)
    }
  }
}

function trackResponse(msg: HubMessage) {
  const now = Date.now()
  const key = `${msg.bot_id}:${msg.channel}`
  const mentionTime = mentionTracker.get(key)
  if (mentionTime) {
    const responseMs = now - mentionTime
    const responseSec = (responseMs / 1000).toFixed(1)
    hubLog('INFO', 'perf', `${msg.bot_id} 响应耗时 ${responseSec}s`, {
      bot_id: msg.bot_id, channel: msg.channel, response_ms: responseMs
    })
    mentionTracker.delete(key)
  }

  // 检测任务完成（消息含"完成"/"done"等关键词）
  const taskEntry = taskTracker.get(msg.bot_id)
  if (taskEntry && /完成|已完成|done|交付|验收/.test(msg.text)) {
    const taskMs = now - taskEntry.start
    const taskMin = (taskMs / 60000).toFixed(1)
    hubLog('INFO', 'perf', `${msg.bot_id} 任务完成 耗时 ${taskMin}min`, {
      bot_id: msg.bot_id, channel: taskEntry.channel, task_ms: taskMs, task: taskEntry.task
    })
    taskTracker.delete(msg.bot_id)
  }

  // 检测任务开始（Lead 分配任务给角色）
  if (msg.mentions.length > 0 && /开始|执行|实现|写|开干|开工/.test(msg.text)) {
    for (const mentioned of msg.mentions) {
      taskTracker.set(mentioned, {
        start: now,
        channel: msg.channel,
        task: msg.text.slice(0, 100),
      })
    }
  }
}

// ======================================================================
// Auth
// ======================================================================

function checkAuth(req: Request): boolean {
  if (!SECRET) return true
  const auth = req.headers.get('authorization')
  if (auth === `Bearer ${SECRET}`) return true
  const url = new URL(req.url)
  if (url.searchParams.get('secret') === SECRET) return true
  return false
}

function unauthorized(): Response {
  return Response.json({ error: 'unauthorized' }, { status: 401 })
}

// CORS headers for mobile/cross-origin access
function corsHeaders(): Record<string, string> {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'access-control-allow-headers': 'content-type, authorization, x-bot-id',
  }
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json', ...corsHeaders() },
  })
}

// ======================================================================
// Rate limiting — keyed by IP + bot_id to prevent bypass
// ======================================================================

const rateLimits = new Map<string, { count: number; resetAt: number }>()
const RATE_LIMIT = 60
const RATE_WINDOW = 60_000

function checkRateLimit(key: string): boolean {
  const now = Date.now()
  const entry = rateLimits.get(key)
  if (!entry || now > entry.resetAt) {
    rateLimits.set(key, { count: 1, resetAt: now + RATE_WINDOW })
    return true
  }
  if (entry.count >= RATE_LIMIT) return false
  entry.count++
  return true
}

// Clean stale rate limit entries every 5 minutes
setInterval(() => {
  const now = Date.now()
  for (const [key, entry] of rateLimits) {
    if (now > entry.resetAt) rateLimits.delete(key)
  }
}, 5 * 60_000)

// ======================================================================
// Mention parsing
// ======================================================================

function parseMentions(text: string): string[] {
  const matches = text.match(/@([\w][\w-]*)/g)
  if (!matches) return []
  // Cap at 20 mentions per message
  return [...new Set(matches.map(m => m.slice(1)))].slice(0, 20)
}

// ======================================================================
// WebSocket connections
// ======================================================================

interface WSClient {
  ws: any
  botId: string
  authed: boolean
  channels: Set<string> | null
  lastPing: number
}

const wsClients = new Set<WSClient>()

function broadcast(frame: WSServerFrame, excludeBotId?: string): void {
  const data = JSON.stringify(frame)
  const dead: WSClient[] = []
  for (const client of wsClients) {
    if (!client.authed) continue
    if (excludeBotId && client.botId === excludeBotId) continue
    if (frame.type === 'message' && client.channels) {
      if (!client.channels.has(frame.data.channel)) continue
    }
    try {
      client.ws.send(data)
    } catch {
      dead.push(client)
    }
  }
  // Clean up dead connections
  for (const c of dead) wsClients.delete(c)
}

// Periodic cleanup: remove stale WS clients (no ping for 5 minutes)
setInterval(() => {
  const cutoff = Date.now() - 5 * 60_000
  for (const client of wsClients) {
    if (client.lastPing < cutoff) {
      try { client.ws.close() } catch {}
      wsClients.delete(client)
    }
  }
}, 60_000)

// ======================================================================
// File helpers
// ======================================================================

const MAX_FILE_SIZE = 25 * 1024 * 1024
const MIME_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.txt': 'text/plain', '.md': 'text/markdown',
  '.pdf': 'application/pdf', '.zip': 'application/zip',
}

// Validate file name: only allow safe characters
function sanitizeFileName(name: string): string | null {
  const safe = name.replace(/[^a-zA-Z0-9._-]/g, '')
  if (!safe || safe.startsWith('.') || safe.includes('..')) return null
  return safe.slice(0, 128)
}

// ======================================================================
// HTTP Router
// ======================================================================

function getBotId(req: Request): string {
  const id = (req.headers.get('x-bot-id') || '').trim()
  return id || 'anonymous'
}

function getClientIP(req: Request): string {
  return req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
    || req.headers.get('x-real-ip')
    || 'unknown'
}

async function safeJson<T>(req: Request): Promise<T | null> {
  try {
    return await req.json() as T
  } catch {
    return null
  }
}

async function handleAPI(req: Request, url: URL): Promise<Response> {
  const path = url.pathname
  const method = req.method

  // CORS preflight
  if (method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders() })
  }

  // --- Typing ---

  // POST /api/typing — broadcast typing indicator
  if (method === 'POST' && path === '/api/typing') {
    const body = await safeJson<{ bot_id: string; channel: string }>(req)
    if (!body || !body.bot_id) return jsonResponse({ error: 'bot_id required' }, 400)
    broadcast({
      type: 'bot_typing',
      data: { bot_id: body.bot_id, channel: body.channel || 'general' },
    })
    return jsonResponse({ ok: true })
  }

  // --- Messages ---

  // POST /api/messages — send message
  if (method === 'POST' && path === '/api/messages') {
    const botId = getBotId(req)
    const ip = getClientIP(req)
    // Rate limit by both bot_id and IP
    if (!checkRateLimit(`bot:${botId}`) || !checkRateLimit(`ip:${ip}`)) {
      return jsonResponse({ error: 'rate limit exceeded' }, 429)
    }
    const body = await safeJson<SendMessageBody>(req)
    if (!body || !body.channel || !body.text) {
      return jsonResponse({ error: 'channel and text required' }, 400)
    }
    // Validate channel name
    if (body.channel.length > 64 || !/^[\w][\w-]*$/.test(body.channel)) {
      return jsonResponse({ error: 'invalid channel name (alphanumeric, dash, underscore, max 64)' }, 400)
    }

    const msg: HubMessage = {
      id: storage.generateMessageId(),
      channel: body.channel,
      bot_id: botId,
      text: body.text.slice(0, 4000), // Cap message length
      mentions: parseMentions(body.text),
      reply_to: body.reply_to || null,
      files: body.files || [],
      reactions: {},
      ts: new Date().toISOString(),
      edited: false,
    }

    storage.appendMessage(msg)
    storage.touchBot(botId)
    broadcast({ type: 'message', data: msg })
    // 性能追踪
    trackMentions(msg)
    trackResponse(msg)
    hubLog('INFO', 'msg', `${botId} → #${msg.channel}`, { id: msg.id, mentions: msg.mentions, len: msg.text.length })
    return jsonResponse({ id: msg.id, ts: msg.ts })
  }

  // GET /api/messages/:channel — fetch history
  if (method === 'GET' && /^\/api\/messages\/[\w][\w-]*$/.test(path)) {
    const channel = decodeURIComponent(path.split('/').pop()!)
    const limit = Math.min(parseInt(url.searchParams.get('limit') || '20'), 100)
    const before = url.searchParams.get('before') || undefined
    const after = url.searchParams.get('after') || undefined
    const messages = storage.getMessages(channel, limit, before, after)
    return jsonResponse(messages)
  }

  // PUT /api/messages/:id — edit message (requires channel in body)
  if (method === 'PUT' && /^\/api\/messages\/msg_[\w]+$/.test(path)) {
    const messageId = path.split('/').pop()!
    const body = await safeJson<{ channel: string; text: string }>(req)
    if (!body || !body.channel || !body.text) {
      return jsonResponse({ error: 'channel and text required' }, 400)
    }
    const botId = getBotId(req)
    const existing = storage.getMessage(body.channel, messageId)
    if (!existing) return jsonResponse({ error: 'not found' }, 404)
    if (existing.bot_id !== botId) return jsonResponse({ error: 'not your message' }, 403)
    const updated = storage.updateMessage(body.channel, messageId, {
      text: body.text.slice(0, 4000),
      mentions: parseMentions(body.text),
    })
    return jsonResponse(updated)
  }

  // POST /api/messages/:id/reactions
  if (method === 'POST' && /^\/api\/messages\/msg_[\w]+\/reactions$/.test(path)) {
    const messageId = path.split('/').slice(-2)[0]
    const body = await safeJson<ReactBody & { channel: string }>(req)
    if (!body || !body.emoji) return jsonResponse({ error: 'emoji required' }, 400)
    const botId = getBotId(req)

    // Search in specified channel first, then all channels
    const searchChannels = body.channel
      ? [{ name: body.channel }]
      : storage.listChannels()

    for (const ch of searchChannels) {
      const msg = storage.getMessage(ch.name, messageId)
      if (msg) {
        if (!msg.reactions[body.emoji]) msg.reactions[body.emoji] = []
        if (!msg.reactions[body.emoji].includes(botId)) {
          msg.reactions[body.emoji].push(botId)
        }
        storage.updateMessage(ch.name, messageId, { reactions: msg.reactions })
        broadcast({
          type: 'reaction',
          data: { message_id: messageId, channel: ch.name, emoji: body.emoji, bot_id: botId, action: 'add' },
        })
        return jsonResponse({ ok: true })
      }
    }
    return jsonResponse({ error: 'message not found' }, 404)
  }

  // --- Channels ---

  if (method === 'GET' && path === '/api/channels') {
    return jsonResponse(storage.listChannels())
  }

  if (method === 'POST' && path === '/api/channels') {
    const body = await safeJson<CreateChannelBody>(req)
    if (!body || !body.name) return jsonResponse({ error: 'name required' }, 400)
    if (body.name.length > 64 || !/^[\w][\w-]*$/.test(body.name)) {
      return jsonResponse({ error: 'invalid channel name' }, 400)
    }
    const ch = storage.createChannel(body.name)
    broadcast({
      type: 'channel_created',
      data: ch,
    })
    return jsonResponse(ch)
  }

  // DELETE /api/channels/:name — delete a channel
  if (method === 'DELETE' && /^\/api\/channels\/[\w][\w-]*$/.test(path)) {
    const channelName = decodeURIComponent(path.split('/').pop()!)
    if (channelName === 'general') {
      return jsonResponse({ error: 'cannot delete #general' }, 400)
    }
    const ok = storage.deleteChannel(channelName)
    if (!ok) return jsonResponse({ error: 'channel not found' }, 404)
    broadcast({ type: 'channel_deleted', data: { name: channelName } })
    hubLog('INFO', 'channel', `deleted #${channelName}`, { by: getBotId(req) })
    return jsonResponse({ ok: true })
  }

  // --- Bots ---

  if (method === 'GET' && path === '/api/bots') {
    return jsonResponse(storage.listBots())
  }

  // --- Projects ---

  if (method === 'GET' && path === '/api/projects') {
    // Build project list from proj-* channels
    const channels = storage.listChannels()
    const projects = channels
      .filter((ch: any) => ch.name.startsWith('proj-'))
      .map((ch: any) => ({
        name: ch.name.replace(/^proj-/, ''),
        channel: ch.name,
        message_count: ch.message_count,
        last_activity: ch.last_message_at,
        created_at: ch.created_at,
      }))
    return jsonResponse(projects)
  }

  // --- Performance stats ---

  if (method === 'GET' && path === '/api/perf') {
    // 读取今天的 hub 日志中的 perf 条目
    const today = new Date().toISOString().slice(0, 10)
    const logFile = join(LOG_DIR, `hub-${today}.log`)
    const perfEntries: any[] = []
    try {
      const content = readFileSync(logFile, 'utf8')
      for (const line of content.trim().split('\n')) {
        try {
          const entry = JSON.parse(line)
          if (entry.cat === 'perf') perfEntries.push(entry)
        } catch {}
      }
    } catch {}
    return jsonResponse(perfEntries)
  }

  // --- Export channel log ---

  if (method === 'GET' && /^\/api\/export\/[\w][\w-]*$/.test(path)) {
    const channelName = decodeURIComponent(path.split('/').pop()!)
    const messages = storage.getMessages(channelName, 9999)
    if (messages.length === 0) return jsonResponse({ error: 'no messages' }, 404)

    let md = `# #${channelName} 对话记录\n\n`
    md += `导出时间: ${new Date().toISOString().slice(0, 19)}\n`
    md += `消息数: ${messages.length}\n\n---\n\n`

    let prevBot = ''
    for (const m of messages) {
      const ts = m.ts.slice(0, 19).replace('T', ' ')
      const edited = m.edited ? ' (已编辑)' : ''
      if (m.bot_id !== prevBot) {
        md += `### [${m.bot_id}] ${ts}${edited}\n\n`
      } else {
        md += `> ${ts}${edited}\n\n`
      }
      md += `${m.text}\n\n`
      prevBot = m.bot_id
    }

    return new Response(md, {
      headers: {
        'Content-Type': 'text/markdown; charset=utf-8',
        'Content-Disposition': `attachment; filename="${channelName}-log.md"`,
        ...corsHeaders(),
      },
    })
  }

  // --- Files ---

  if (method === 'POST' && path === '/api/files') {
    const formData = await req.formData()
    const file = formData.get('file') as File | null
    if (!file) return jsonResponse({ error: 'no file' }, 400)
    if (file.size > MAX_FILE_SIZE) {
      return jsonResponse({ error: `file too large (max ${MAX_FILE_SIZE / 1024 / 1024}MB)` }, 413)
    }
    const fileId = `f_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`
    const ext = extname(file.name).replace(/[^a-zA-Z0-9.]/g, '') || '.bin'
    const fileName = `${fileId}${ext}`
    const filePath = join(storage.filesDir(), fileName)
    const buf = Buffer.from(await file.arrayBuffer())
    writeFileSync(filePath, buf)
    return jsonResponse({ file_id: fileName, size: file.size })
  }

  if (method === 'GET' && path.startsWith('/api/files/')) {
    const rawName = path.slice('/api/files/'.length)
    const fileName = sanitizeFileName(rawName)
    if (!fileName) return jsonResponse({ error: 'invalid file name' }, 400)
    const filePath = join(storage.filesDir(), fileName)
    // Double-check resolved path is within files dir
    if (!resolve(filePath).startsWith(resolve(storage.filesDir()))) {
      return jsonResponse({ error: 'forbidden' }, 403)
    }
    if (!existsSync(filePath)) return jsonResponse({ error: 'not found' }, 404)
    const content = readFileSync(filePath)
    const ext = extname(fileName)
    const contentType = MIME_TYPES[ext] || 'application/octet-stream'
    return new Response(content, {
      headers: { 'content-type': contentType, 'content-length': String(content.byteLength), ...corsHeaders() },
    })
  }

  // --- Health ---

  if (method === 'GET' && path === '/api/health') {
    return jsonResponse({
      status: 'ok',
      uptime: process.uptime(),
      clients: wsClients.size,
      bots: storage.listBots().length,
    })
  }

  return jsonResponse({ error: 'not found' }, 404)
}

// ======================================================================
// Static file serving (Web UI)
// ======================================================================

function serveStatic(urlPath: string): Response | null {
  const uiDir = resolve(join(import.meta.dir, 'ui'))
  const filePath = resolve(join(uiDir, urlPath === '/' ? 'index.html' : urlPath))

  // Security: ensure resolved path is within ui/
  if (!filePath.startsWith(uiDir)) return null
  if (!existsSync(filePath)) return null
  const stat = statSync(filePath)
  if (!stat.isFile()) return null

  const content = readFileSync(filePath)
  const ext = extname(filePath)
  const contentType = MIME_TYPES[ext] || 'application/octet-stream'
  return new Response(content, {
    headers: { 'content-type': contentType, 'cache-control': 'no-cache' },
  })
}

// ======================================================================
// Bun Server
// ======================================================================

const server = Bun.serve({
  port: PORT,
  hostname: HOST,

  fetch(req, server) {
    const url = new URL(req.url)

    // CORS preflight for any route
    if (req.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders() })
    }

    // WebSocket upgrade
    if (url.pathname === '/ws') {
      const upgraded = server.upgrade(req, {
        data: { botId: '', authed: false, channels: null, lastPing: Date.now() } as WSClient,
      })
      return upgraded ? undefined : new Response('upgrade failed', { status: 400 })
    }

    // API routes
    if (url.pathname.startsWith('/api/')) {
      if (!checkAuth(req)) return unauthorized()
      try {
        return handleAPI(req, url)
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err)
        hubLog('ERROR', 'api', `${req.method} ${url.pathname}: ${msg}`)
        return jsonResponse({ error: 'internal error' }, 500)
      }
    }

    // Static UI with auth gate
    if (SECRET) {
      const cookies = req.headers.get('cookie') || ''
      const hasAuthCookie = cookies.includes(`hub_secret=${SECRET}`)
      const hasQuerySecret = url.searchParams.get('secret') === SECRET
      if (!hasAuthCookie && !hasQuerySecret) {
        if (url.pathname === '/login') {
          return serveStatic('/login.html') || new Response('not found', { status: 404 })
        }
        if (url.pathname.endsWith('.css') || url.pathname.endsWith('.js')) {
          return serveStatic(url.pathname) || new Response('not found', { status: 404 })
        }
        return new Response(null, { status: 302, headers: { location: '/login' } })
      }
      if (hasQuerySecret && !hasAuthCookie) {
        const staticResp = serveStatic(url.pathname)
        if (staticResp) {
          const newResp = new Response(staticResp.body, staticResp)
          newResp.headers.set('set-cookie', `hub_secret=${SECRET}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000`)
          return newResp
        }
      }
    }

    return serveStatic(url.pathname) || new Response('not found', { status: 404 })
  },

  websocket: {
    open(ws) {
      const client: WSClient = { ws, botId: '', authed: false, channels: null, lastPing: Date.now() }
      ;(ws as any).__client = client
      wsClients.add(client)
      // Auto-close if not authenticated within 10 seconds
      setTimeout(() => {
        if (!client.authed) {
          try { ws.close() } catch {}
          wsClients.delete(client)
        }
      }, 10_000)
    },
    message(ws, raw) {
      const client = (ws as any).__client as WSClient
      client.lastPing = Date.now()
      let frame: WSClientFrame
      try { frame = JSON.parse(String(raw)) } catch { return }

      if (frame.type === 'auth') {
        if (SECRET && frame.secret !== SECRET) {
          hubLog('WARN', 'ws', 'auth failed: invalid secret', { bot_id: frame.bot_id })
          ws.send(JSON.stringify({ type: 'auth_fail', reason: 'invalid secret' }))
          ws.close()
          return
        }
        if (!frame.bot_id || typeof frame.bot_id !== 'string') {
          hubLog('WARN', 'ws', 'auth failed: bot_id required')
          ws.send(JSON.stringify({ type: 'auth_fail', reason: 'bot_id required' }))
          ws.close()
          return
        }
        client.botId = frame.bot_id.trim()
        client.authed = true
        const bots = storage.listBots().map(b => b.bot_id)
        ws.send(JSON.stringify({ type: 'auth_ok', bots }))
        broadcast({ type: 'bot_joined', bot_id: client.botId }, client.botId)
        hubLog('INFO', 'ws', `${client.botId} connected`, { total_clients: wsClients.size })
        return
      }

      // Ping keepalive — just update lastPing
      if (frame.type === 'ping') return

      // All other frame types require auth
      if (!client.authed) return

      if (frame.type === 'subscribe') {
        client.channels = new Set(frame.channels)
      }
    },
    close(ws) {
      const client = (ws as any).__client as WSClient
      hubLog('INFO', 'ws', `${client.botId || 'unknown'} disconnected`, { total_clients: wsClients.size - 1 })
      wsClients.delete(client)
    },
  },
})

// ======================================================================
// Startup
// ======================================================================

const localIP = getLocalIP()
hubLog('INFO', 'hub', 'Hub started', { port: PORT, host: HOST, data_dir: DATA_DIR })

console.log(`
╔══════════════════════════════════════════╗
║          MulitBot Hub Started            ║
╠══════════════════════════════════════════╣
║  Local:   http://127.0.0.1:${PORT}          ║
║  LAN:     http://${localIP}:${PORT}${' '.repeat(Math.max(0, 15 - localIP.length))}║
║  Auth:    ${SECRET ? 'ENABLED (HUB_SECRET)' : 'DISABLED (local only)'}${' '.repeat(SECRET ? 4 : 2)}║
║  WS:      ws://${localIP}:${PORT}/ws${' '.repeat(Math.max(0, 11 - localIP.length))}║
╚══════════════════════════════════════════╝
`)

if (SECRET) {
  console.log(`手机访问: http://${localIP}:${PORT}?secret=${SECRET}`)
  console.log('')
}

if (TUNNEL === 'cloudflared') startTunnel()

// ======================================================================
// Helpers
// ======================================================================

function getLocalIP(): string {
  try {
    const interfaces = require('os').networkInterfaces()
    for (const name of Object.keys(interfaces)) {
      for (const iface of interfaces[name] || []) {
        if (iface.family === 'IPv4' && !iface.internal) return iface.address
      }
    }
  } catch {}
  return '0.0.0.0'
}

async function startTunnel(): Promise<void> {
  try {
    const proc = Bun.spawn(['cloudflared', 'tunnel', '--url', `http://127.0.0.1:${PORT}`], {
      stdout: 'pipe', stderr: 'pipe',
    })
    const reader = proc.stderr.getReader()
    const decoder = new TextDecoder()
    let buffer = ''
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value)
      const match = buffer.match(/(https:\/\/[a-z0-9-]+\.trycloudflare\.com)/)
      if (match) {
        console.log(`公网地址: ${match[1]}`)
        if (SECRET) console.log(`手机访问: ${match[1]}?secret=${SECRET}`)
        break
      }
    }
  } catch {
    console.error('cloudflared 启动失败')
  }
}
