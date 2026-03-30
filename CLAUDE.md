# MulitBot — 多角色动态协同框架

## 项目概述

通用的多 Claude Code 实例协作框架。客户通过手机 Web UI 提需求，**老板 Claude Code** 自动组建团队、管理项目。系统根据需求自动生成角色灵魂（人格 + 决策框架 + 工具权限），团队通过自托管 Hub 消息服务器协同工作。

**不限于特定项目类型** — 游戏、API 服务、数据平台、前端应用等任何软件项目都适用。

## 架构

```
客户（手机 Web UI）
  ↕ #general 频道（客户-Boss 专线）
老板 Claude Code (bots/boss/)
  ↕ 创建 #proj-xxx 频道，分配任务
MulitBot Hub (plugins/multibot-hub/hub.ts)
  ↕ WebSocket + HTTP
┌─────────┬──────────┬──────────┐
│ Lead    │ 架构师    │ 产品/美术 │  ← 团队成员（动态生成/复用）
└─────────┴──────────┴──────────┘
  ↕ monitor.sh 自动唤醒 + 崩溃恢复 + typing 广播
```

## 目录结构

```
bots/
  boss/                   - 老板 Claude Code（管理入口）
    i18n/                 - Boss 多语言模板（CLAUDE.en.md, CLAUDE.zh-CN.md）
  lead/                   - 主持人（按 role-id 命名）
  architect/              - 架构师
  product/                - 产品经理
  artist/                 - 美术/UI设计
  tester/                 - 测试工程师
  <role-id>/              - 其他动态生成的角色
    CLAUDE.md             - 角色定义（frontmatter + 灵魂 + _base.md）
    .claude/settings.json - Claude Code 设置（禁用 Discord 等全局插件）
    .mcp.json             - Hub MCP 插件配置

plugins/
  multibot-hub/           - 自托管消息系统
    hub.ts                - Hub 服务主进程（HTTP + WebSocket + Web UI + 日志）
    server.ts             - MCP 插件（Claude Code ↔ Hub 桥梁 + 日志）
    storage.ts            - JSONL 存储层（频道 CRUD、消息、Bot 注册）
    types.ts              - TypeScript 类型定义（含所有 WebSocket 帧类型）
    ui/                   - 手机端 Web UI
      index.html          - 主页面（频道标签 + 消息 + 输入框 + 中断按钮）
      login.html          - 密钥登录页
      style.css           - 暗色主题样式（含通知、未读、typing 指示器）
      app.js              - 客户端逻辑（WebSocket + 通知 + 项目列表 + 中断）
      lang.js             - Web UI i18n（自动检测浏览器语言或 ?lang= URL 参数）

roles/
  _base.md                - 所有角色共享的基础规则（通信、防循环、记忆、经验沉淀）
  i18n/                   - 基础规则多语言版本（_base.en.md 等）
  <role-id>.md            - 角色模板（可跨项目复用）
  <role-id>.experience.md - 角色跨项目经验档案（上下文压缩前滚动积累）

projects/
  <项目名>/               - 每个项目独立工作区
    workspace/
      tasks/              - Worker 任务
      results/            - Worker 结果
      decisions/          - 决策记录
      team-knowledge/     - 团队共享记忆
    code/                 - 项目代码

scripts/
  start.sh                - 一键启动（Hub + Boss + Monitor），团队按需启动，含 team.json 校验 + 陈旧 tmux 会话自动清理
  stop.sh                 - 停止所有进程（Hub/Boss/团队/Monitor）
  boss.sh                 - 单独启动老板 Claude Code（终端交互模式）
  hub-start.sh            - 启动 Hub 消息服务器
  recruit.sh              - 招聘/复用角色（支持 --reuse + 经验文件载入）
  add-member.sh           - 运行中动态加人（含 monitor 自动重启）
  list-roles.sh           - 列出可复用的角色模板（支持 --json/--detail）
  monitor.sh              - 消息监控守护进程（唤醒 + 崩溃恢复 + typing 广播 + 日志）
  wake.sh                 - 手动唤醒指定 Bot
  setup.sh                - 初始化 Bot 目录环境
  worker.sh               - 派发 Worker 任务
  i18n.sh                 - 脚本国际化库（zh-CN/en/ja），从系统 $LANG 或 team.json "lang" 字段自动检测语言
  export-log.sh           - 频道对话导出为 Markdown 纪要
  debrief.sh              - 项目复盘（收集各角色经验 → retrospective.md + experience 文件）

mcp-shared.json             - 共享 MCP 技能配置（Figma 等），add-member.sh 自动合并到 bot 的 .mcp.json

data/
  channels/               - 频道数据（每频道一个目录：meta.json + messages.jsonl）
  logs/                   - 统一日志目录
    hub-YYYY-MM-DD.log    - Hub 请求/连接/错误日志
    monitor-YYYY-MM-DD.log - Monitor 唤醒/重启/崩溃日志
    system-YYYY-MM-DD.log - start.sh/stop.sh 启停日志
    mcp-<bot>-YYYY-MM-DD.log - 各 Bot MCP 插件工具调用日志
  bots.json               - Bot 注册信息
  files/                  - 上传文件存储

team.json                 - 当前团队配置（必须包含 hub 节，可含 "lang" 字段指定语言）
.gitignore                - Git 忽略规则
LICENSE                   - 许可证
README.md                 - 项目说明
```

## 核心流程

### 1. 启动

```bash
# 一键启动（Hub + Boss + Monitor，团队成员按需启动）
bash scripts/start.sh

# 公网模式（手机可远程访问）
HUB_SECRET=my-secret bash scripts/start.sh
```

启动后自动运行（仅 3 个进程，懒加载模式）：
- Hub 消息服务器（tmux: hub），自动确保 #general 频道存在
- Boss Claude Code（tmux: boss）— 唯一初始 claude 实例
- Monitor 守护进程（tmux: monitor）

**团队成员不预启动**，由 Boss 收到客户需求后通过 `add-member.sh` 按需拉起，避免空闲 claude 实例浪费资源。

启动时校验 team.json 格式，缺少 `hub` 节自动补全。**自动清理陈旧 tmux 会话**（Hub 已死但 tmux 会话残留的情况）。

### 2. 客户提需求

客户在手机浏览器打开 Hub 地址（如 `http://192.168.x.x:7800`），在 `#general` 频道发消息：

```
@boss 帮我做一个贪吃蛇游戏
```

发送后立即显示"等待 boss 回复..."指示器。Monitor 唤醒 boss 时广播 typing 事件，UI 显示"boss 正在处理..."。

### 3. Boss 组建团队

Boss Claude Code 收到消息后自动：
1. 分析需求，按项目类型确定角色清单（至少 Lead + 产品 + 架构）
2. 查看已有角色 `list-roles.sh`，优先复用
3. 逐个启动团队成员：`add-member.sh --reuse <role-id> --project <项目名>`（自动更新 team.json）
4. 创建项目频道 `#proj-snake`（客户端自动收到频道创建通知）
5. 在 `#general` 告诉客户团队已组建
6. 在 `#proj-snake` 发项目简报给团队

### 4. 团队讨论（强制流程）

```
Boss 在 #proj-snake 发简报 → Monitor 唤醒 Lead
Lead 拆解议题 → @product @architect @artist 提问
  ↓
1. 需求讨论（产品主导）：用户场景、优先级、验收标准
2. 设计讨论（美术主导）：视觉风格、配色、交互
3. 技术方案（架构师主导）：选型、模块、风险
  ↓
Lead 综合决策 → 写入 decisions/ → 开始执行
```

**禁止跳过讨论直接写代码。** 所有角色都可以 @mention 其他角色进行技术讨论，不限于 Lead 分发。

### 5. 客户监控与操作

客户在手机上可以：
- **查看讨论**：切换频道标签查看各项目团队讨论
- **项目列表**：侧栏 Projects 显示所有项目及消息数
- **实时通知**：@client 或"完成/验收通过"消息触发声音、振动、浏览器推送
- **未读标记**：频道标签红色闪烁圆点，标签页标题显示未读数
- **追加指令**：在 `#general` 给 boss 发新需求或修改
- **中断项目**：项目频道 header 的 ■ 按钮，一键通知 boss 停止
- **删除频道**：侧栏频道列表 hover 显示 × 按钮（#general 禁止删除）

### 6. 按需加人

所有团队成员通过 `add-member.sh` 启动（包括初始组建和后续追加）：

```bash
# Boss 组建团队时逐个启动
bash scripts/add-member.sh --reuse lead --project snake
bash scripts/add-member.sh --reuse product --project snake
bash scripts/add-member.sh --reuse architect --project snake

# 后续追加角色
bash scripts/add-member.sh --reuse tester --project snake
bash scripts/add-member.sh "数据库专家，精通 PostgreSQL 和 Redis"
```

每次调用自动：更新 team.json → 启动 Claude Code → 重启 Monitor → 频道通知。
已在运行的角色会自动跳过，不会重复启动。

### 7. 项目完成/关闭

项目完成时 Boss 先执行团队复盘 `debrief.sh`，收集每个角色的经验总结：
- 生成 `projects/<名>/workspace/retrospective.md`（复盘报告）
- 自动追加到各角色 `roles/<id>.experience.md`（跨项目经验）
- 导出完整项目纪要

客户说"中断项目"→ Boss 通知团队停止 + 复盘 + 汇报客户。**Boss 绝不执行 stop.sh（会杀掉自己）**。

## 通信系统（multibot-hub）

自托管消息服务：

- **Bot 身份**：字符串 ID（如 `lead`, `architect`），零注册
- **客户身份**：`client`，通过 Web UI 发消息
- **@mention**：纯文本 `@bot-id`，直接写在消息文本中
- **频道隔离**：
  - `#general` — 客户与 Boss 专线（Monitor 只唤醒 Boss，Hub 启动时自动创建，禁止删除）
  - `#proj-xxx` — 项目团队讨论（Monitor 唤醒所有相关角色，可删除）
- **存储**：JSONL 文件，追加写入
- **实时推送**：WebSocket 事件驱动（message, channel_created, channel_deleted, bot_typing, bot_joined, reaction），MCP 连接有 2 分钟 keepalive ping 防止 Hub 超时断开

### API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | /api/health | 健康检查 |
| POST | /api/messages | 发送消息 |
| GET | /api/messages/:channel | 获取频道消息 |
| PUT | /api/messages/:id | 编辑消息 |
| POST | /api/messages/:id/reactions | 添加 Reaction |
| GET | /api/channels | 列出频道 |
| POST | /api/channels | 创建频道 |
| DELETE | /api/channels/:name | 删除频道（#general 禁止） |
| GET | /api/bots | 列出 Bot |
| GET | /api/projects | 列出项目（从 proj-* 频道提取） |
| POST | /api/typing | 广播 typing 指示器 |
| POST | /api/files | 上传文件 |
| GET | /api/files/:id | 下载文件 |
| GET | /api/export/:channel | 导出频道对话为 Markdown |
| GET | /api/perf | 查看今日性能数据（响应耗时、任务耗时） |

### 消息路由

| 角色 | mention_mode | 行为 |
|------|-------------|------|
| Boss | all | 收到所有频道的所有消息 |
| Lead | all | 收到所在频道的所有消息 |
| 其他 | mention | 只收到 @自己 的消息 |
| Client | — | Web UI 显示所有频道所有消息 |

### 防循环

1. **频道隔离**：`#general` 只唤醒 Boss，防止团队成员抢答客户
2. **3 轮限制**：两人对话超过 3 轮未解决，必须 @lead 介入
3. **不回弹**：不要 @刚回复你的人，除非有新信息
4. **汇报收口**：讨论完毕 @lead 汇报结论
5. **硬限制**：Hub 速率限制 60条/分钟/bot

### 安全

| 场景 | 配置 |
|------|------|
| 纯本机 | 默认，无需配置 |
| 局域网（手机查看） | `HUB_SECRET=xxx`，绑定 0.0.0.0 |
| 公网远程 | `HUB_SECRET=xxx` + cloudflared 隧道 |

防护措施：密钥认证、IP+bot_id 双重速率限制、WebSocket 10秒认证超时、文件路径穿越校验、CORS 头、频道名验证、#general 删除保护、#general 发消息权限控制（仅 boss/client 可发，团队成员 403）。

## 角色系统

### 灵魂生成

角色不是硬编码的。`recruit.sh` 调用 Claude 自动生成：

- YAML frontmatter（name, id, description, mention_mode, tools）
- 人格定义（身份、性格、决策框架）
- 工具权限（frontmatter `tools` 字段）
- 回复风格（结构化专业模板）
- 记忆重点（该角色应该积累的经验类型）

### 角色复用

生成的角色模板保存在 `roles/` 目录，可跨项目复用：

```bash
# 查看可复用角色
bash scripts/list-roles.sh

# 复用已有角色（不调 Claude API，秒完成，自动载入历史经验）
bash scripts/recruit.sh 2 false --reuse architect

# 新招聘（调 Claude API 生成灵魂）
bash scripts/recruit.sh 3 false "安全审计专家"
```

### 团队组建规则

**任何项目至少 3 人**（Lead + 产品 + 架构），按需加人：

| 项目特征 | 必须包含的角色 |
|---------|--------------|
| 所有项目 | Lead + 产品 + 架构（最低 3 人） |
| 有 UI/视觉 | + 美术 |
| 质量敏感 | + 测试 |
| 前后端分离 | + 前端/后端专家 |

### 角色间通信

所有角色都可以 @mention 同项目的其他角色，不限于 Lead 分发。防循环规则：两人对话不超过 3 轮、不回弹、完成后 @lead 汇报。

## 记忆系统

三层记忆架构：

**个体记忆**（auto-memory）：每个 Bot 从独立 `bots/<id>/` 目录启动，Claude Code 内置 memory 自动持久化，跨对话保留。

**共享记忆**（workspace/team-knowledge/）：所有角色可读写的团队知识库，格式 `## 日期 — 标题\n内容\n`。

**跨项目经验**（roles/<id>.experience.md）：角色在上下文压缩前自动将关键经验写入经验档案，复用角色时自动载入 CLAUDE.md 末尾的 `## 历史经验` 章节。经验随项目积累，角色越用越强。

## Monitor 守护进程

`monitor.sh` 在 tmux 的 monitor 窗口持续运行：

- **消息监控**：每 10 秒轮询 Hub API，检测有未读 @mention 的 Bot
- **自动唤醒**：向空闲 Bot 发送 tmux 消息触发 fetch_messages
- **Typing 广播**：唤醒 Bot 时调用 Hub `/api/typing`，客户端显示"xxx 正在处理..."
- **频道隔离**：`#general` 只唤醒 Boss，项目频道唤醒对应角色
- **崩溃恢复**：检测 Bot tmux 窗口中 claude 进程是否存活，崩溃后自动重启 + 15s 后唤醒恢复上下文（restart_bot 在 role_name 缺失时回退到 bot_id，兼容无 frontmatter 的 boss）
- **唤醒冷却**：同一 Bot 30 秒内不重复唤醒，避免消息排队卡住
- **卡住检测**：发现 Claude Code "queued messages" 状态时自动按 Enter 解除
- **处理中识别**：识别 Running/Thinking/Brewing 等活跃状态，不打断正在工作的 Bot
- **重启冷却**：60 秒内不重复重启同一 Bot
- **日志输出**：同时写入终端和 `data/logs/monitor-YYYY-MM-DD.log`

## 日志系统

所有组件统一写入 `data/logs/` 目录，JSON 格式，按日期分文件：

| 日志文件 | 来源 | 内容 |
|---------|------|------|
| `hub-YYYY-MM-DD.log` | Hub 主进程 | 启动、消息收发、WebSocket 连接/断开、频道操作、API 错误 |
| `monitor-YYYY-MM-DD.log` | Monitor 守护进程 | 唤醒事件、崩溃检测、重启操作 |
| `system-YYYY-MM-DD.log` | start.sh / stop.sh | 系统启停、Bot 启动记录 |
| `mcp-<bot-id>-YYYY-MM-DD.log` | 各 Bot MCP 插件 | 工具调用、WebSocket 消息收发、连接断开 |

```bash
# 排查问题
cat data/logs/*-$(date +%Y-%m-%d).log | sort       # 今天所有日志
grep '"ERROR"' data/logs/*.log                       # 所有错误
cat data/logs/mcp-boss-*.log                         # Boss 的活动
grep '"cat":"msg"' data/logs/hub-*.log               # 消息流
```

## 性能追踪

Hub 自动追踪两类性能指标：

- **响应耗时**：从 @mention 到被 mention 的 bot 回复的时间
- **任务耗时**：从 Lead 分配任务到角色报告完成的时间

```bash
# 查看今日性能数据
grep '"perf"' data/logs/hub-$(date +%Y-%m-%d).log

# API 查看（手机可访问）
curl http://127.0.0.1:7800/api/perf
```

Monitor 也记录唤醒到回复的耗时：`grep "PERF" data/logs/monitor-*.log`

## Worker 派发

角色 Bot 执行 `bash scripts/worker.sh <task_file>` 启动临时 Claude Code 进程：
- Worker 是无状态的 `claude --print` 进程
- 结果写入 workspace/results/
- 角色 Bot 只读摘要，不在讨论上下文中执行重活

## 国际化（i18n）

全栈三层 i18n 支持：

- **脚本层**（`scripts/i18n.sh`）：所有 shell 脚本的用户提示信息支持 zh-CN / en / ja，语言从系统 `$LANG` 环境变量或 team.json `"lang"` 字段自动检测
- **角色层**（`roles/i18n/`, `bots/boss/i18n/`）：基础规则和 Boss 模板的多语言版本，Boss i18n 模板包含显式语言强制指令（"IMPORTANT: Always communicate in English/中文"）
- **Web UI 层**（`plugins/multibot-hub/ui/lang.js`）：前端界面 i18n，自动检测浏览器语言或通过 `?lang=` URL 参数指定

## 手机 Web UI

功能：
- **频道标签栏**：快速切换 `#general` / `#proj-xxx`，有新消息显示红色闪烁圆点
- **实时消息**：WebSocket 推送，@mention 高亮，同作者 2 分钟内消息合并显示
- **发消息**：以 `client` 身份与 Boss 沟通，发送后显示等待指示器
- **项目列表**：侧栏显示所有项目（从 proj-* 频道提取）及消息数
- **通知系统**：@client 或"完成/验收"消息触发声音（Web Audio）、振动、浏览器推送、标题未读数
- **Typing 指示器**：Bot 被唤醒时显示"xxx 正在处理..."，回复后自动消失
- **中断项目**：项目频道 header 的 ■ 按钮，通知 boss 停止工作
- **删除频道**：侧栏频道 hover 显示 × 按钮（#general 受保护禁止删除）
- **@mention 自动补全**：输入 @ 弹出已知 Bot 列表
- **Bot 状态**：侧栏显示 Bot 列表，处理中的显示"处理中..."标记

## team.json 格式规范

```json
{
  "project": "项目名",
  "lang": "zh-CN",
  "hub": {
    "port": 7800,
    "secret": "",
    "default_channel": "general"
  },
  "slots": [
    {"slot": 1, "id": "lead", "role": "lead", "soul": "角色描述"},
    {"slot": 2, "id": "product", "role": "member", "soul": "角色描述"},
    {"slot": 3, "id": "architect", "role": "member", "soul": "角色描述"}
  ]
}
```

**格式规则：**
- 必须有 `hub` 节（port/secret/default_channel），start.sh 缺失时自动补全
- 可选 `lang` 字段（"zh-CN" / "en" / "ja"），指定项目语言，影响脚本提示和角色模板选择
- 每个 slot：`slot`（数字）、`id`（英文，匹配 bots/ 目录名）、`role`（"lead" 或 "member"）、`soul`（描述）
- slot 1 永远是 lead
