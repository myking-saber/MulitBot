#!/usr/bin/env bun
// ======================================================================
// MulitBot Hub — MCP Plugin for Claude Code
//
// Drop-in replacement for multibot-discord. Same MCP tool names,
// talks to the local Hub server via HTTP + WebSocket.
// ======================================================================

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import type { HubMessage } from './types'
import { appendFileSync, mkdirSync } from 'fs'
import { join } from 'path'

const HUB_URL = (process.env.HUB_URL || 'http://127.0.0.1:7800').replace(/\/$/, '')
const BOT_ID = (process.env.BOT_ID || '').trim()
const BOT_ROLE = process.env.BOT_ROLE || ''
const MENTION_MODE = process.env.MENTION_MODE || 'mention'
const HUB_SECRET = process.env.HUB_SECRET || ''
const DEFAULT_CHANNEL = process.env.HUB_CHANNEL || 'general'

if (!BOT_ID) {
  process.stderr.write('multibot-hub: BOT_ID is required\n')
  process.exit(1)
}

if (!/^[\w][\w-]*$/.test(BOT_ID)) {
  process.stderr.write(`multibot-hub: invalid BOT_ID "${BOT_ID}" — must be alphanumeric with dashes\n`)
  process.exit(1)
}

process.stderr.write(`multibot-hub: bot_id=${BOT_ID} role=${BOT_ROLE} mode=${MENTION_MODE}\n`)

// Logging — find project root from HUB_URL or env
const MCP_DATA_DIR = process.env.HUB_DATA_DIR || join(import.meta.dir, '..', '..', 'data')
const LOG_DIR = join(MCP_DATA_DIR, 'logs')
try { mkdirSync(LOG_DIR, { recursive: true }) } catch {}

function mcpLog(level: string, msg: string) {
  const ts = new Date().toISOString()
  const line = JSON.stringify({ ts, level, cat: `mcp:${BOT_ID}`, msg })
  try {
    appendFileSync(join(LOG_DIR, `mcp-${BOT_ID}-${ts.slice(0, 10)}.log`), line + '\n')
  } catch {}
}

// ======================================================================
// HTTP client
// ======================================================================

function authHeaders(): Record<string, string> {
  const h: Record<string, string> = { 'X-Bot-Id': BOT_ID }
  if (HUB_SECRET) h['Authorization'] = `Bearer ${HUB_SECRET}`
  return h
}

async function hubFetch(method: string, path: string, body?: unknown): Promise<any> {
  const headers: Record<string, string> = { ...authHeaders() }
  const opts: RequestInit = { method, headers }
  if (body) {
    headers['Content-Type'] = 'application/json'
    opts.body = JSON.stringify(body)
  }
  const res = await fetch(`${HUB_URL}/api${path}`, opts)
  const text = await res.text()
  if (!res.ok) {
    throw new Error(`hub ${method} ${path}: ${res.status} ${text.slice(0, 200)}`)
  }
  try {
    return JSON.parse(text)
  } catch {
    throw new Error(`hub ${method} ${path}: invalid JSON: ${text.slice(0, 200)}`)
  }
}

// ======================================================================
// MCP Server
// ======================================================================

const roleInstruction = BOT_ROLE
  ? `\nYou are acting as the "${BOT_ROLE}" role in a multi-bot team. Stay in character.\n`
  : ''

const mcp = new Server(
  { name: 'multibot-hub', version: '0.1.0' },
  {
    capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
    instructions: [
      roleInstruction,
      'You are connected to a team chat hub. Other bots and the human boss communicate here.',
      '',
      'Messages arrive as <channel source="multibot-hub" chat_id="..." message_id="..." user="..." ts="...">.',
      'Use the reply tool to send messages. Pass chat_id (channel name) back.',
      '@mentions use plain text: @bot-id (e.g., @architect, @lead).',
      'Use fetch_messages to read channel history.',
    ].join('\n'),
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description: 'Send a message to a channel.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'Channel name.' },
          text: { type: 'string' },
          reply_to: { type: 'string', description: 'Message ID to reply to.' },
        },
        required: ['chat_id', 'text'],
      },
    },
    {
      name: 'fetch_messages',
      description: 'Fetch recent messages from a channel. Returns oldest-first.',
      inputSchema: {
        type: 'object',
        properties: {
          channel: { type: 'string' },
          limit: { type: 'number', description: 'Max messages (default 20, max 100).' },
        },
        required: ['channel'],
      },
    },
    {
      name: 'react',
      description: 'Add an emoji reaction to a message.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string' },
          message_id: { type: 'string' },
          emoji: { type: 'string' },
        },
        required: ['chat_id', 'message_id', 'emoji'],
      },
    },
    {
      name: 'edit_message',
      description: 'Edit a message you previously sent.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string' },
          message_id: { type: 'string' },
          text: { type: 'string' },
        },
        required: ['chat_id', 'message_id', 'text'],
      },
    },
    {
      name: 'list_channels',
      description: 'List all channels.',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'create_channel',
      description: 'Create a new channel.',
      inputSchema: {
        type: 'object',
        properties: { name: { type: 'string' } },
        required: ['name'],
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  mcpLog('INFO', `tool:${req.params.name} args=${JSON.stringify(args).slice(0, 200)}`)
  try {
    switch (req.params.name) {
      case 'reply': {
        const result = await hubFetch('POST', '/messages', {
          channel: args.chat_id as string,
          text: args.text as string,
          reply_to: args.reply_to as string | undefined,
        })
        return { content: [{ type: 'text', text: `sent (id: ${result.id})` }] }
      }
      case 'fetch_messages': {
        const channel = args.channel as string
        const limit = Math.min((args.limit as number) || 20, 100)
        const messages = await hubFetch('GET', `/messages/${encodeURIComponent(channel)}?limit=${limit}`)
        if (!Array.isArray(messages) || messages.length === 0) {
          return { content: [{ type: 'text', text: '(no messages)' }] }
        }
        const lines = messages.map((m: HubMessage) => {
          const who = m.bot_id === BOT_ID ? 'me' : m.bot_id
          return `[${m.ts}] ${who}: ${m.text}  (id: ${m.id})`
        })
        return { content: [{ type: 'text', text: lines.join('\n') }] }
      }
      case 'react': {
        await hubFetch('POST', `/messages/${args.message_id}/reactions`, {
          channel: args.chat_id as string,
          emoji: args.emoji as string,
        })
        return { content: [{ type: 'text', text: 'reacted' }] }
      }
      case 'edit_message': {
        await hubFetch('PUT', `/messages/${args.message_id}`, {
          channel: args.chat_id as string,
          text: args.text as string,
        })
        return { content: [{ type: 'text', text: 'edited' }] }
      }
      case 'list_channels': {
        const channels = await hubFetch('GET', '/channels')
        if (!Array.isArray(channels) || channels.length === 0) {
          return { content: [{ type: 'text', text: '(no channels)' }] }
        }
        const lines = channels.map((c: any) => `#${c.name} (${c.message_count} msgs)`)
        return { content: [{ type: 'text', text: lines.join('\n') }] }
      }
      case 'create_channel': {
        const ch = await hubFetch('POST', '/channels', { name: args.name as string })
        return { content: [{ type: 'text', text: `created #${ch.name}` }] }
      }
      default:
        return { content: [{ type: 'text', text: `unknown tool: ${req.params.name}` }], isError: true }
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    mcpLog('ERROR', `tool:${req.params.name} failed: ${msg}`)
    return { content: [{ type: 'text', text: `${req.params.name} failed: ${msg}` }], isError: true }
  }
})

// ======================================================================
// WebSocket — receive messages from Hub, with proper reconnection
// ======================================================================

let currentWs: WebSocket | null = null
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let pingInterval: ReturnType<typeof setInterval> | null = null

function connectHub(): void {
  // Close existing connection to prevent leaks
  if (currentWs) {
    try { currentWs.close() } catch {}
    currentWs = null
  }
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }

  const wsUrl = HUB_URL.replace(/^http/, 'ws') + '/ws'
  process.stderr.write(`multibot-hub: connecting to ${wsUrl}\n`)

  const ws = new WebSocket(wsUrl)
  currentWs = ws

  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'auth', bot_id: BOT_ID, secret: HUB_SECRET }))
  }

  ws.onmessage = (event) => {
    let frame: any
    try { frame = JSON.parse(String(event.data)) } catch { return }

    if (frame.type === 'auth_ok') {
      mcpLog('INFO', `ws connected, bots: ${frame.bots?.join(', ') || 'none'}`)
      process.stderr.write(`multibot-hub: connected, bots: ${frame.bots?.join(', ') || 'none'}\n`)
      // Start keepalive ping every 2 minutes (Hub timeout is 5 min)
      if (pingInterval) clearInterval(pingInterval)
      pingInterval = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'ping' }))
        }
      }, 120_000)
    }

    if (frame.type === 'auth_fail') {
      mcpLog('ERROR', `ws auth failed: ${frame.reason}`)
      process.stderr.write(`multibot-hub: auth failed: ${frame.reason}\n`)
      return
    }

    if (frame.type === 'message') {
      const msg = frame.data as HubMessage
      if (msg.bot_id === BOT_ID) return
      if (MENTION_MODE === 'mention' && !msg.mentions.includes(BOT_ID)) return

      mcpLog('INFO', `ws:incoming #${msg.channel} from=${msg.bot_id} len=${msg.text.length}`)
      void mcp.notification({
        method: 'notifications/claude/channel',
        params: {
          content: msg.text,
          meta: {
            chat_id: msg.channel,
            message_id: msg.id,
            user: msg.bot_id,
            ts: msg.ts,
            bot_role: BOT_ROLE,
            ...(msg.bot_id !== 'boss' ? { is_bot: 'true' } : {}),
          },
        },
      })
    }
  }

  ws.onclose = () => {
    if (ws !== currentWs) return // Stale connection, ignore
    if (pingInterval) { clearInterval(pingInterval); pingInterval = null }
    mcpLog('WARN', 'ws disconnected, reconnecting in 3s')
    process.stderr.write('multibot-hub: disconnected, reconnecting in 3s...\n')
    currentWs = null
    reconnectTimer = setTimeout(connectHub, 3000)
  }

  ws.onerror = () => {
    // onclose will fire after
  }
}

// ======================================================================
// Start
// ======================================================================

await mcp.connect(new StdioServerTransport())
connectHub()
