// ======================================================================
// MulitBot Hub — JSONL Storage Layer
// ======================================================================

import { mkdirSync, appendFileSync, readFileSync, writeFileSync, existsSync, readdirSync, rmSync, renameSync } from 'fs'
import { join } from 'path'
import type { HubMessage, HubChannel, HubBot } from './types'

export class Storage {
  private dataDir: string
  private channelsDir: string
  private bots: Map<string, HubBot> = new Map()

  constructor(dataDir: string) {
    this.dataDir = dataDir
    this.channelsDir = join(dataDir, 'channels')
    mkdirSync(this.channelsDir, { recursive: true })
    mkdirSync(join(dataDir, 'files'), { recursive: true })
    this.loadBots()
  }

  // --- Message ID generation ---

  generateMessageId(): string {
    const ts = Date.now()
    const rand = Math.random().toString(36).slice(2, 6)
    return `msg_${ts}_${rand}`
  }

  // --- Channel operations ---

  private channelDir(channel: string): string {
    // Sanitize channel name
    const safe = channel.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64)
    return join(this.channelsDir, safe)
  }

  private ensureChannel(channel: string): void {
    const dir = this.channelDir(channel)
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true })
      const meta: HubChannel = {
        name: channel,
        created_at: new Date().toISOString(),
        last_message_at: null,
        message_count: 0,
      }
      writeFileSync(join(dir, 'meta.json'), JSON.stringify(meta, null, 2))
    }
  }

  listChannels(): HubChannel[] {
    if (!existsSync(this.channelsDir)) return []
    const dirs = readdirSync(this.channelsDir, { withFileTypes: true })
      .filter(d => d.isDirectory())
    const channels: HubChannel[] = []
    for (const d of dirs) {
      const metaPath = join(this.channelsDir, d.name, 'meta.json')
      try {
        channels.push(JSON.parse(readFileSync(metaPath, 'utf8')))
      } catch {
        channels.push({
          name: d.name,
          created_at: new Date().toISOString(),
          last_message_at: null,
          message_count: 0,
        })
      }
    }
    return channels.sort((a, b) => (b.last_message_at ?? '').localeCompare(a.last_message_at ?? ''))
  }

  createChannel(name: string): HubChannel {
    this.ensureChannel(name)
    const metaPath = join(this.channelDir(name), 'meta.json')
    return JSON.parse(readFileSync(metaPath, 'utf8'))
  }

  deleteChannel(name: string): boolean {
    const dir = this.channelDir(name)
    if (!existsSync(dir)) return false
    try {
      rmSync(dir, { recursive: true, force: true })
      return true
    } catch (e) {
      process.stderr.write(`storage: deleteChannel failed for ${name}: ${e}\n`)
      return false
    }
  }

  // --- Message operations ---

  appendMessage(msg: HubMessage): void {
    this.ensureChannel(msg.channel)
    const dir = this.channelDir(msg.channel)
    const line = JSON.stringify(msg) + '\n'
    appendFileSync(join(dir, 'messages.jsonl'), line)

    // Update channel meta
    const metaPath = join(dir, 'meta.json')
    try {
      const meta: HubChannel = JSON.parse(readFileSync(metaPath, 'utf8'))
      meta.last_message_at = msg.ts
      meta.message_count++
      writeFileSync(metaPath, JSON.stringify(meta, null, 2))
    } catch (e) {
      process.stderr.write(`storage: meta update failed for ${msg.channel}: ${e}\n`)
    }
  }

  getMessages(channel: string, limit = 20, before?: string, after?: string): HubMessage[] {
    const dir = this.channelDir(channel)
    const filePath = join(dir, 'messages.jsonl')
    if (!existsSync(filePath)) return []

    const content = readFileSync(filePath, 'utf8')
    const lines = content.trim().split('\n').filter(Boolean)
    let messages: HubMessage[] = lines.map(line => {
      try { return JSON.parse(line) } catch { return null }
    }).filter(Boolean) as HubMessage[]

    // Filter by cursor
    if (before) {
      const idx = messages.findIndex(m => m.id === before)
      if (idx > 0) messages = messages.slice(0, idx)
    }
    if (after) {
      const idx = messages.findIndex(m => m.id === after)
      if (idx >= 0) messages = messages.slice(idx + 1)
    }

    // Return last N messages (oldest first)
    if (messages.length > limit) {
      messages = messages.slice(-limit)
    }
    return messages
  }

  getMessage(channel: string, messageId: string): HubMessage | null {
    const dir = this.channelDir(channel)
    const filePath = join(dir, 'messages.jsonl')
    if (!existsSync(filePath)) return null

    const content = readFileSync(filePath, 'utf8')
    for (const line of content.trim().split('\n')) {
      try {
        const msg = JSON.parse(line) as HubMessage
        if (msg.id === messageId) return msg
      } catch {}
    }
    return null
  }

  // Write lock per channel to prevent read-modify-write race conditions
  private writeLocks = new Map<string, Promise<void>>()

  private async withWriteLock<T>(channel: string, fn: () => T): Promise<T> {
    const existing = this.writeLocks.get(channel) || Promise.resolve()
    let resolve: () => void
    const newLock = new Promise<void>(r => { resolve = r })
    this.writeLocks.set(channel, newLock)
    await existing
    try {
      return fn()
    } finally {
      resolve!()
    }
  }

  updateMessage(channel: string, messageId: string, updates: Partial<HubMessage>): HubMessage | null {
    const dir = this.channelDir(channel)
    const filePath = join(dir, 'messages.jsonl')
    if (!existsSync(filePath)) return null

    // Atomic: write to tmp file, then rename
    const content = readFileSync(filePath, 'utf8')
    const lines = content.trim().split('\n')
    let updated: HubMessage | null = null

    const newLines = lines.map(line => {
      try {
        const msg = JSON.parse(line) as HubMessage
        if (msg.id === messageId) {
          const merged = { ...msg, ...updates, edited: true }
          updated = merged
          return JSON.stringify(merged)
        }
        return line
      } catch { return line }
    })

    if (updated) {
      const tmpPath = filePath + '.tmp'
      writeFileSync(tmpPath, newLines.join('\n') + '\n')
      renameSync(tmpPath, filePath)
    }
    return updated
  }

  // --- Bot registry ---

  private botsFile(): string {
    return join(this.dataDir, 'bots.json')
  }

  private loadBots(): void {
    const file = this.botsFile()
    if (!existsSync(file)) return
    try {
      const data = JSON.parse(readFileSync(file, 'utf8')) as HubBot[]
      for (const bot of data) {
        this.bots.set(bot.bot_id, bot)
      }
    } catch {}
  }

  private saveBots(): void {
    writeFileSync(this.botsFile(), JSON.stringify([...this.bots.values()], null, 2))
  }

  touchBot(botId: string): void {
    const now = new Date().toISOString()
    const existing = this.bots.get(botId)
    if (existing) {
      existing.last_seen = now
      existing.message_count++
    } else {
      this.bots.set(botId, {
        bot_id: botId,
        first_seen: now,
        last_seen: now,
        message_count: 1,
      })
    }
    this.saveBots()
  }

  listBots(): HubBot[] {
    return [...this.bots.values()].sort((a, b) => a.bot_id.localeCompare(b.bot_id))
  }

  // --- File storage ---

  filesDir(): string {
    return join(this.dataDir, 'files')
  }
}
