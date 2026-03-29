// ======================================================================
// MulitBot Hub — Shared types
// ======================================================================

export interface HubMessage {
  id: string
  channel: string
  bot_id: string
  text: string
  mentions: string[]
  reply_to: string | null
  files: string[]
  reactions: Record<string, string[]>  // emoji → [bot_id, ...]
  ts: string
  edited: boolean
}

export interface HubChannel {
  name: string
  created_at: string
  last_message_at: string | null
  message_count: number
}

export interface HubBot {
  bot_id: string
  first_seen: string
  last_seen: string
  message_count: number
}

// WebSocket frames
export type WSClientFrame =
  | { type: 'auth'; bot_id: string; secret?: string }
  | { type: 'subscribe'; channels: string[] }

export type WSServerFrame =
  | { type: 'auth_ok'; bots: string[] }
  | { type: 'auth_fail'; reason: string }
  | { type: 'message'; data: HubMessage }
  | { type: 'reaction'; data: { message_id: string; channel: string; emoji: string; bot_id: string; action: 'add' | 'remove' } }
  | { type: 'bot_joined'; bot_id: string }
  | { type: 'bot_typing'; data: { bot_id: string; channel: string } }
  | { type: 'channel_created'; data: HubChannel }
  | { type: 'channel_deleted'; data: { name: string } }

// API request bodies
export interface SendMessageBody {
  channel: string
  text: string
  reply_to?: string
  files?: string[]
}

export interface ReactBody {
  emoji: string
}

export interface CreateChannelBody {
  name: string
}
