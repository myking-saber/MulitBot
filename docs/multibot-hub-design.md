# MulitBot Hub — 自托管消息系统设计文档

## 1. 为什么要替换 Discord

| Discord 的问题 | Hub 的解决方案 |
|---------------|--------------|
| 每个 Bot 需要独立 Token，手动注册 | Bot 用字符串 ID 标识，零注册 |
| 不能动态创建 Bot / 频道 | 频道和 Bot 按需自动创建 |
| 消息速率限制 | 本地通信，无限制 |
| @mention 用不透明的数字 ID | `@architect` 直接用角色名 |
| 依赖外部服务（网络/隐私/稳定性） | 完全自托管，数据本地 |
| 手机查看需要 Discord 客户端 | 自带移动端 Web UI |

## 2. 整体架构

```
                    ┌──────────────────────────────────┐
                    │        multibot-hub (Bun)        │
                    │          单进程，单端口            │
                    │                                  │
  手机浏览器 ──────►│  Web UI    HTTP API    WebSocket  │
                    │  /        /api/*      /ws        │
                    │         ┌─────────────────┐      │
                    │         │   Message Bus    │      │
                    │         └────────┬────────┘      │
                    │                  │               │
                    │         ┌────────┴────────┐      │
                    │         │  JSONL Storage   │      │
                    │         │  data/channels/  │      │
                    │         └─────────────────┘      │
                    └────────────┬───────────────────┬──┘
                                 │                   │
                    ┌────────────┴──┐    ┌───────────┴──┐
                    │  MCP Plugin   │    │  MCP Plugin   │  ...
                    │  (slot-1)     │    │  (slot-2)     │
                    │  lead         │    │  architect    │
                    │  stdio ↔ HTTP │    │  stdio ↔ HTTP │
                    └───────────────┘    └──────────────┘
```

**三个组件：**
1. **Hub Server** — Bun 单进程，提供 HTTP API + WebSocket + 静态 Web UI
2. **MCP Plugin** — 每个 Claude Code 实例一份，通过 HTTP/WS 与 Hub 通信
3. **Web UI** — 纯 HTML/CSS/JS，手机浏览器访问

## 3. 身份与安全

### 3.1 身份标识

取消 Discord Token 体系。每个 Bot 用 `bot_id` 字符串标识（对应 CLAUDE.md frontmatter 中的 `id` 字段）。

```
Lead Bot    → bot_id: "lead"
Architect   → bot_id: "architect"
人类老板     → bot_id: "boss"
```

### 3.2 安全模型

Hub 默认运行在 `127.0.0.1`（仅本机访问）。根据使用场景分三个安全等级：

**等级 1：纯本机（默认）**
```
绑定: 127.0.0.1:7800
认证: 无（本机进程天然可信）
适用: 所有 Bot 和老板都在同一台机器
```

**等级 2：局域网（手机查看）**
```
绑定: 0.0.0.0:7800
认证: HUB_SECRET 共享密钥
适用: 老板通过手机在局域网内访问
```

所有请求需携带密钥：
- HTTP: `Authorization: Bearer <HUB_SECRET>` 请求头
- WebSocket: 连接时发送 `{"type":"auth","secret":"<HUB_SECRET>"}`
- Web UI: 首次打开输入密码，存入 localStorage

**等级 3：公网远程（外出查看）**
```
绑定: 127.0.0.1:7800（不直接暴露）
隧道: cloudflared / tailscale / frp
认证: HUB_SECRET + HTTPS（隧道提供）
适用: 老板在外面通过手机查看
```

### 3.3 安全措施清单（已实现）

| 威胁 | 措施 | 状态 |
|------|------|------|
| 未授权访问 | HUB_SECRET 密钥认证（HTTP Header + WS auth frame + Cookie） | ✅ |
| 中间人窃听 | 局域网：密钥+内网隔离；公网：HTTPS 隧道（cloudflared） | ✅ |
| Bot 冒充 | bot_id 由启动参数传入，BOT_ID 格式验证（`^[\w][\w-]*$`） | ✅ |
| 速率限制绕过 | IP + bot_id 双重限制（60条/分钟/维度） | ✅ |
| 文件路径穿越 | sanitizeFileName + resolve() 双重校验 | ✅ |
| 文件上传滥用 | 25MB 大小限制 + 文件名净化 | ✅ |
| WebSocket 未认证泄漏 | 10秒认证超时自动断开 + 5分钟空闲清理 | ✅ |
| WS 僵尸连接内存泄漏 | 定时清理 + broadcast 中清除发送失败的连接 | ✅ |
| 频道名注入 | 正则验证 `^[\w][\w-]*$`，长度限制 64 | ✅ |
| 消息过长 | 文本截断 4000 字符，mention 上限 20 个 | ✅ |
| 跨域请求 | CORS headers + OPTIONS preflight | ✅ |
| 数据竞态（updateMessage） | 写锁 + 原子 rename 替代直接 writeFile | ✅ |
| 数据泄露 | 数据目录权限控制 | ✅ |

## 4. 数据存储

### 4.1 消息格式

每个频道一个目录，消息追加写入 JSONL 文件：

```
data/
  channels/
    general/
      messages.jsonl    # 追加写入，每行一条消息
      meta.json         # 频道元信息
    task-123/
      messages.jsonl
  files/
    f_1711500000_a1b2.png   # 上传的附件
```

消息结构：

```json
{
  "id": "msg_1711500000000_a1b2",
  "channel": "general",
  "bot_id": "lead",
  "text": "@architect @product 请评估这个需求",
  "mentions": ["architect", "product"],
  "reply_to": null,
  "files": [],
  "reactions": {"👍": ["boss"], "✅": ["architect"]},
  "ts": "2026-03-27T10:00:00.000Z",
  "edited": false
}
```

### 4.2 为什么选 JSONL 而不是 SQLite

- 零依赖，Bun 原生文件 I/O
- 追加写入天然防崩溃（只 append，不改已有行）
- 可直接 `cat` / `grep` 查看，调试友好
- 团队规模（几个 Bot、每次讨论几百条消息）下性能完全够用
- 如果未来需要搜索，替换成 SQLite 只改 storage 层

## 5. Hub HTTP API

### 5.1 消息

```
POST   /api/messages                    发送消息
GET    /api/messages/:channel?limit=20  拉取历史（支持 before/after 游标）
PUT    /api/messages/:id                编辑消息
POST   /api/messages/:id/reactions      添加 reaction
DELETE /api/messages/:id/reactions/:emoji  移除 reaction
```

发送消息请求体：
```json
{
  "channel": "general",
  "text": "@architect 请评估技术方案",
  "reply_to": "msg_xxx",      // 可选
  "files": ["f_xxx.png"]      // 可选，先上传再引用
}
```

`bot_id` 从请求头 `X-Bot-Id` 读取（MCP Plugin 启动时固定）。

### 5.2 频道

```
GET    /api/channels                    列出所有频道
POST   /api/channels                    创建频道 {"name": "design-review"}
```

频道在首条消息时也会自动创建（隐式）。

### 5.3 Bot 注册

```
GET    /api/bots                        列出所有已知 Bot
```

Bot 在发送首条消息时自动注册，无需手动操作。

### 5.4 文件

```
POST   /api/files                       上传文件（multipart）
GET    /api/files/:file_id              下载文件
```

## 6. WebSocket 协议

连接 `ws://host:7800/ws`，JSON 文本帧。

```
→ 客户端认证
{"type":"auth","bot_id":"lead","secret":"xxx"}

← 服务端确认
{"type":"auth_ok","bots":["lead","architect","product"]}

← 新消息推送
{"type":"message","data":{"id":"msg_xxx","channel":"general","bot_id":"architect","text":"...","mentions":[],"ts":"..."}}

← reaction 推送
{"type":"reaction","data":{"message_id":"msg_xxx","emoji":"👍","bot_id":"boss"}}

→ 订阅特定频道（可选，默认订阅全部）
{"type":"subscribe","channels":["general","task-123"]}
```

## 7. MCP Plugin

替换 `multibot-discord`，保持相同的工具名称，Claude Code 无感切换。

### 7.1 环境变量

| 变量 | 说明 | 示例 |
|------|------|------|
| `HUB_URL` | Hub 服务地址 | `http://127.0.0.1:7800` |
| `BOT_ID` | 本 Bot 的身份 | `lead` |
| `BOT_ROLE` | 角色名（注入 MCP instructions） | `主持人` |
| `MENTION_MODE` | `all` 或 `mention` | `all`（Lead），`mention`（其他） |
| `HUB_SECRET` | 共享密钥（可选） | `my-secret-key` |
| `HUB_CHANNEL` | 默认频道 | `general` |

### 7.2 MCP 工具映射

| MCP Tool | 实现 |
|----------|------|
| `reply(chat_id, text, reply_to?, files?)` | `POST /api/messages` |
| `fetch_messages(channel, limit?)` | `GET /api/messages/:channel` |
| `react(chat_id, message_id, emoji)` | `POST /api/messages/:id/reactions` |
| `edit_message(chat_id, message_id, text)` | `PUT /api/messages/:id` |
| `list_channels()` | `GET /api/channels` — **新增** |
| `create_channel(name)` | `POST /api/channels` — **新增** |

### 7.3 消息接收

Plugin 启动时连接 WebSocket。收到消息后根据 `MENTION_MODE` 过滤：

```typescript
function shouldDeliver(msg: Message): boolean {
  // 忽略自己发的
  if (msg.bot_id === BOT_ID) return false
  // Lead 模式：收所有
  if (MENTION_MODE === 'all') return true
  // Mention 模式：只收 @自己的
  return msg.mentions.includes(BOT_ID)
}
```

通过后，发送 MCP notification：

```typescript
mcp.notification({
  method: 'notifications/claude/channel',
  params: {
    content: msg.text,
    meta: {
      chat_id: msg.channel,
      message_id: msg.id,
      user: msg.bot_id,
      ts: msg.ts,
      bot_role: BOT_ROLE,
      is_bot: msg.bot_id !== 'boss' ? 'true' : undefined
    }
  }
})
```

## 8. Web UI（手机端）

### 8.1 功能

- 频道列表侧边栏（可折叠）
- 消息流（实时 WebSocket 更新，自动滚到底部）
- 每个 bot_id 有固定颜色头像标识
- Reaction 显示
- 响应式布局（手机优先，暗色主题）
- **只读监控模式** — 无输入框，老板要干预通过终端跟老板 Claude Code 说

### 8.2 技术选择

纯 HTML/CSS/JS，无构建步骤，Bun 直接 serve 静态文件。

### 8.3 认证流程

设置 HUB_SECRET 后，Web UI 有登录页面：
1. 用户访问 Hub 地址 → 重定向到 `/login`
2. 输入密码 → 带 `?secret=` 跳转主页
3. 服务端设置 HttpOnly Cookie（30天有效）
4. 后续访问通过 Cookie 认证

## 9. @mention 系统

### 9.1 语法

纯文本 `@bot_id`，例如：

```
@architect @product 请评估这个需求
```

Hub 在收到消息时解析 `@(\w[\w-]*)` 模式，填充 `mentions` 数组。

### 9.2 与 Discord 的对比

| | Discord | Hub |
|--|---------|-----|
| 语法 | `<@1234567890>` | `@architect` |
| 可读性 | 差（需解析） | 好（直接可读） |
| 稳定性 | Bot 重建后 ID 变 | ID 永远不变 |
| 发现成本 | 需 fetch_messages 找 ID | 无需发现 |

### 9.3 CLAUDE.md 影响

所有角色模板中的 `<@BOT_USER_ID>` 改为 `@bot-id`：

```
# 之前（Discord）
回复时在末尾 @主持人 Bot（用 `<@LEAD_BOT_USER_ID>`）

# 之后（Hub）
回复时在末尾 @lead，通知主持人你已完成回复
```

Lead 的 `fetch_messages` 不再需要发现其他 Bot 的 ID。

## 10. 文件结构

```
plugins/
  multibot-hub/
    hub.ts              # Hub 服务主进程（HTTP + WS + 静态文件）
    server.ts           # MCP Plugin（Claude Code ↔ Hub 桥梁）
    storage.ts          # JSONL 存储层（带写锁 + 原子写入）
    types.ts            # 共享类型定义
    package.json        # 依赖：@modelcontextprotocol/sdk
    .mcp.json           # MCP 插件注册（./server.ts）
    .claude-plugin/
      plugin.json       # Claude Code 插件元信息
    ui/
      index.html        # 只读监控 SPA
      login.html        # 密码登录页
      style.css         # 移动优先暗色主题
      app.js            # WebSocket 客户端 + 渲染逻辑

bots/
  boss/                 # 老板 Claude Code（管理入口）
    CLAUDE.md           # 老板行为指令
  slot-1/ ~ slot-N/     # 动态团队成员

projects/
  <项目名>/             # 每个项目独立工作区
    team.json
    workspace/{tasks,results,decisions,team-knowledge}
    code/

scripts/
  boss.sh               # 一键启动老板（自动启动 Hub）
  hub-start.sh           # 独立启动 Hub
  start.sh               # 启动团队（读 team.json）
  stop.sh                # 停止 Hub + 团队（Hub 发 Ctrl+C，Bot 发 /exit）
  recruit.sh             # 动态招聘
  setup.sh               # 初始化 Slot 环境
  worker.sh              # Worker 任务派发
```

## 11. 使用流程

### 老板模式（推荐）

```bash
# 一键启动（自动启动 Hub + 老板 Claude Code）
bash scripts/boss.sh

# 公网模式
HUB_SECRET=my-secret bash scripts/boss.sh
```

老板在终端说"帮我做一个XX项目"，老板 Claude Code 自动：
1. 创建项目工作区 `projects/<项目名>/`
2. 分析需求，决定团队组成
3. 调用 recruit.sh 生成每个角色灵魂
4. 启动团队
5. 发送项目简报

### 手动模式

```bash
bash scripts/hub-start.sh
bash scripts/recruit.sh 1 true  "主持人描述"
bash scripts/recruit.sh 2 false "架构师描述"
bash scripts/start.sh
```

### 关闭项目

老板说"关闭项目"→ 执行 `bash scripts/stop.sh`，数据保留在 `projects/` 目录。

## 12. 多项目支持

每个项目有独立的工作区：

```
projects/
  task-manager/          # 项目 A
    team.json
    workspace/
    code/
  e-commerce/            # 项目 B
    team.json
    workspace/
    code/
```

- 同一时间只运行一个项目团队（Hub 是共享的）
- 切换项目：stop → 切换 team.json → start
- 项目数据永久保留，可随时恢复

## 13. 实现状态

| 组件 | 状态 | 说明 |
|------|------|------|
| Hub 核心 (hub.ts) | ✅ 完成 | HTTP API + WS + 静态文件 |
| 存储层 (storage.ts) | ✅ 完成 | JSONL + 写锁 + 原子写入 |
| MCP 插件 (server.ts) | ✅ 完成 | 6 个 MCP 工具 + WS 重连 |
| Web UI | ✅ 完成 | 只读监控 + 登录 + 暗色主题 |
| 安全加固 | ✅ 完成 | 13 项安全措施 |
| 脚本集成 | ✅ 完成 | boss.sh / start.sh / stop.sh |
| 动态招聘 | ✅ 完成 | recruit.sh + Claude 生成灵魂 |
| 多项目 | ✅ 完成 | projects/ 独立工作区 |

## 14. 配置示例

### team.json

```json
{
  "project": "my-app",
  "hub": {
    "port": 7800,
    "secret": "",
    "default_channel": "general"
  },
  "slots": [
    { "slot": 1, "role": "lead",   "soul": "冷静果断的项目总监" },
    { "slot": 2, "role": "member", "soul": "技术洁癖的架构师" },
    { "slot": 3, "role": "member", "soul": "悲观主义测试工程师" }
  ]
}
```

### 环境变量（自动由脚本传入）

```bash
# Hub 进程
HUB_PORT=7800  HUB_HOST=0.0.0.0  HUB_SECRET=xxx  HUB_DATA_DIR=./data

# 每个 Bot 的 MCP Plugin
HUB_URL=http://127.0.0.1:7800  BOT_ID=architect  BOT_ROLE=架构师  MENTION_MODE=mention
```
