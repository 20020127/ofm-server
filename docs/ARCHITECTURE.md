# 架构与逆向分析报告

> 分析对象：`Ebony-Vinyl/dsh-our-free-model`（MIT License）
> 上游版本：插件 `2.1.0` / standalone 包 `0.1.0`
> 分析方式：源码级静态分析（依赖闭包遍历 + 关键模块通读）+ 重构后本机实测
> 本文件回答四个问题：**核心功能、请求流程、鉴权机制、依赖项**。

---

## 1. 它是什么

`dsh-our-free-model` 是 DeepSeek Harness（dsh）的插件，把一个 **OpenAI 兼容的本地推理网关** 装进 dsh：无需登录、注册或填写 API Key，即可调用一批前沿模型。

模型的来源不是一家，而是**四条通道（lane）**：

| 通道 | 凭证 | 模型示例 | 说明 |
|---|---|---|---|
| 匿名免费通道 | 无 | `ling-3.1-flash-free`、`step-5-preview-free` 等 | 固定 base URL 直连，靠请求形态（指纹工具声明）过上游免费闸门 |
| Kilo 免费池 | 无 | `kilo-auto/free`、`nvidia/nemotron-3-ultra-550b-a55b:free` | Kilo AI 的 OpenAI 兼容网关免费切片，最简单的一条车道 |
| EAC 协付通道 | GitHub 授权 | 随资源池动态变化 | AES-256-GCM 密封的车道凭据指向签名网关，真实上游凭证只存在网关侧 |
| 十三个账号渠道 | 各渠道 OAuth 登录 | `provider/model` 形式 | CodeArts、CodeBuddy、WorkBuddy、LobsterAI、Qoder、TRAE、Cline、Loomy、Raccoon、MiniMax Code、ZCode、Gemini 等，登录后走账号自己的免费额度，支持账号池轮换、续期、签到、积分账本 |

上游官方提供 `packages/standalone` 作为**脱离 dsh 的独立服务入口**（本文档所述重构即基于它）。

---

## 2. 请求流程

### 2.1 整体链路

```
客户端（任何 OpenAI 兼容 SDK / curl）
  │  POST /v1/chat/completions   Authorization: Bearer ofm-xxx
  ▼
┌─────────────────────────────────────────────────────────────┐
│ forward.js  startForwardServer（HTTP 监听，仅回环）            │
│                                                             │
│  1. handleRequest? ──yes──► management.mjs（页面/管理 API）   │
│  2. settings.enabled ──false──► 503                          │
│  3. OPTIONS ──► 204 CORS 预检                                │
│  4. / 或 /health ──► 200（免密钥，只答存活）                   │
│  5. Bearer/x-api-key 校验 ──fail──► 401                      │
│  6. GET  /v1/models        ──► 模型清单                       │
│     POST /v1/chat/completions ──► 补全（流式/非流式）          │
│     POST /v1/responses        ──► Responses 协议              │
│     POST /v1/messages         ──► Anthropic 协议              │
└─────────────────────────────────────────────────────────────┘
  │ complete(request, onChunk)
  ▼
┌─────────────────────────────────────────────────────────────┐
│ service.mjs 组装的 runtime                                   │
│                                                             │
│  model 形如 "<provider>/..."？                               │
│    ├─ 是 ─► channels.complete                               │
│    │        Worker 线程 ─► channels/worker.mjs               │
│    │        └─ channels/business.mjs（68k 行渠道包，          │
│    │           13 家适配器：登录/账号池/续期/签到/积分）         │
│    └─ 否 ─► core.complete（src/core/runtime.js）              │
│             ├─ 匿名免费通道（src/adapter.js）                  │
│             ├─ Kilo 免费池（src/kilo.js）                     │
│             └─ EAC 密封车道（src/eac.js + vault.js）           │
└─────────────────────────────────────────────────────────────┘
  │ onChunk(chunk) 逐块回吐
  ▼
SSE 流式回传（forward.js 的 serveCompletion）
  · tool_calls[].index 从 0 重新编号（修复稀疏数组合并/丢参数）
  · 抑制指向指纹诱饵工具（bash/glob/grep/read）的工具调用
```

### 2.2 几个值得知道的实现细节

**端口自动顺延。** 默认 18900，被占用时依次尝试后续端口（最多扫描 10 个），实际端口写入 `settings.json` 的 `standalonePort`，下次启动优先沿用。`--port 0` 表示系统分配。

**模型清单后台加载。** 启动先绑定 HTTP，账号渠道在 Worker 里异步初始化，不阻塞端口就绪；`/health` 立即可答。

**SSE 纪律。** 响应体先嗅探（`sniffBody`）再信 Content-Type；头部字节回放（`replayStream`）保证首 token 不缓冲；空闲流按超时掐断（Kilo 的 `: KILO PROCESSING` 注释行会被跳过但不触发空闲判定）。

**断流恢复。** `streamRecovery` 设置控制流中断后的恢复行为（默认开）。

**统计。** 记录用量与性能（TTFT、解码速度、token 数），**不保存提示词和回答**。

### 2.3 对外基地址的推导（本仓库新增）

管理接口返回的 `info().baseUrl` 是前端「API 接入」面板与 curl 示例展示给用户的接入地址。上游把它硬编码成**回环绑定地址**（`http://127.0.0.1:18900`）—— 这是「本机桌面插件」的假设：插件与服务同机，回环地址可达。经反向代理 + 域名 + TLS 暴露时，这个值就变成用户照抄必败的死地址。

本仓库新增 `src/public-url.js`（构建期从 `tools/patches/public-url.js` 拷入），推导优先级：

| 优先级 | 来源 | 场景 |
|---|---|---|
| 1 | `OFM_PUBLIC_BASE_URL` 环境变量 | CDN / 多层网关等反代不方便透传头的形态 |
| 2 | `X-Forwarded-Proto` + `X-Forwarded-Host` | 本仓库 nginx 反代形态（vhost 已透传原始 Host） |
| 3 | 回环绑定地址 | 上游原有行为，本机直连不受影响 |

`X-Forwarded-Host` 由客户端可控，因此**仅当请求自身的 `Host` 已是回环名时才采信**（上游 `structuralRejection` 对管理端强制要求回环 Host，能到达的请求必然已过闸门，等价于「确认来自受信反代」）；直连暴露时自动落到第 3 优先级。值本身还过一道 authority 形态校验（只放行 `DNS名[:端口]` / `[IPv6][:端口]`），且**只用于界面展示，不参与任何出网请求**。细节与回滚方法见 `docs/PRODUCTION.md` §3.3.1。

---

## 3. 鉴权机制（四层，相互独立）

### 3.1 推理 API Key（`forwardKey`）

- 首次启动自动生成：`ofm-` + 24 随机字节 base64url；
- 明文存放于数据目录 `settings.json`，目录权限 0700；
- 请求经 `Authorization: Bearer <key>` 或 `x-api-key: <key>` 提交；
- **恒定时间比较**（`crypto.timingSafeEqual`，先比长度），防时序侧信道；
- 轮换（`POST /api/management/key/rotate`）立即使旧密钥失效，仅当前管理会话保留。

### 3.2 管理页面会话

- 启动时生成**一次性引导令牌**，放在管理链接的 URL fragment（`#login=...`），10 分钟有效、仅可兑换一次，兑换后置空；
- 兑换成功得到 HttpOnly + SameSite=Strict + Path=/api/management 的 Cookie，8 小时有效；
- 也可以直接用 API Key 登录（等价路径）；
- 管理接口还有同源防护：Host 必须是回环名（`structuralRejection`），`/api/management/login/terminal` 额外要求同源 Origin + `sec-fetch-site: same-origin`。

### 3.3 EAC 协付授权（GitHub OAuth）

- 车道凭据以 AES-256-GCM **密封**在发布物内（`src/vault-data.js` + `src/vault-anchor.js` 三个分片异或掩码后拼接，HKDF 派生密钥；任何单个文件或全文检索都还原不出明文）；
- worker 模式：密封内容 = 签名网关 URL + 签名密钥；真实上游凭证只存在网关侧，提取出的密封件是网关可吊销的间接入口；
- 用户在管理页点「EAC 授权」→ 打开 `${网关}/auth/github/start?link=<随机 link>` → GitHub 授权 → 轮询（`createEacLoginPoller`）拿到用户 token，存数据目录 `eac-user.json`；
- **本重构未绕过、未修改该闸门**：`packages/standalone/eac.mjs` 与上游逐字节一致（仅改了 import 路径）。

### 3.4 账号渠道凭据

- 十三个渠道各自 OAuth/扫码登录，凭据存数据目录 `channel-credentials.json`；
- 账号池、优先级、积分锁定、账本在 `channel-pack/` 子目录；
- 备份导出为**明文凭据文件**，需妥善保管（上游 README 原文提醒）。

---

## 4. 依赖项

### 4.1 运行时依赖：零 npm 包

对入口做完整相对导入闭包分析（静态 import/export-from/createRequire 遍历）：

| 类别 | 文件数 | 内容 |
|---|---|---|
| 入口与管理 | 5 | `cli.mjs`、`service.mjs`、`management.mjs`、`eac.mjs`、`login-terminal.mjs` |
| 渠道 Worker | 5 | `channels/{worker,business,contracts,credentials,images}.mjs` |
| 核心 src/ | 52 | forward/http/anthropic/kilo/eac/vault/store/probe/stream/token-saver 等 |
| 预构建前端 | 14 | `web/`（index.html + app.js + assets.json + 按需分块） |
| 二进制资产 | 1 | `vendor/channel-pack/qoder-auth-wasm.wasm`（Qoder 渠道签名用） |

**没有任何裸包名 import**——只用 Node 内置模块。`npm install` 在运行时不需要执行。

### 4.2 运行环境

| 项 | 要求 | 说明 |
|---|---|---|
| Node.js | `^22.19.0 \|\| >=24.0.0` | 上游 engines 字段；用了 `Worker` + `AbortSignal.any` 等 |
| 操作系统 | Linux / macOS / Windows | 服务本身跨平台；「自动打开终端取令牌」仅 Win/macOS |
| 网络 | 出网可达各上游 | Kilo、Gemini（Google）、各渠道 API；支持 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`（遵守 `NO_PROXY`，回环不走代理） |
| 磁盘 | 数百 MB | 数据目录（凭据/账目/缓存/统计） |
| JDK | **不需要** | 与 Ghidra 无关，纯 Node 服务 |

### 4.3 数据目录文件清单

默认 `~/.our-free-model`（环境变量 `OFM_HOME` 或 `--data-dir` 覆盖）：

```
settings.json            # API Key（forwardKey）、端口、设置项、目录同步时间
service.lock             # 单实例锁（wx 独占创建；正常退出清除）
channel-credentials.json # 十三个渠道的账号凭据
eac-user.json            # EAC GitHub 授权
catalog.json             # 模型清单缓存（上游不可达时保留）
stats.json               # 用量统计（不含 prompt/回答）
channel-pack/            # 账号池、积分、账本、签到状态、CodeArts 缓存
```

---

## 5. 从插件到独立服务：重构做了什么

上游 standalone 依赖完整仓库的相对路径，不能单独拷贝运行。本项目的 `tools/build-app.mjs` 做了四件事：

1. **闭包提取**：从 `packages/standalone/cli.mjs` 与 `channels/worker.mjs` 两个入口遍历静态导入，复制 81 个运行时文件；
2. **扁平化 + 路径改写**：`packages/standalone/*` 提升到 `app/` 根，`../../src/` → `./src/`、`../../../src/` → `../src/`、`../../../vendor/` → `../vendor/`（共 12 处，脚本自动完成，可重复执行）；
3. **附带运行时资产**：`web/` 预构建前端、`src/providers/registry.json`（运行时 readFileSync 读取）、Qoder WASM、上游 LICENSE 与溯源文件 `UPSTREAM.md`；
4. **服务器部署补丁**（`SERVER_PATCHES`）：把 `info()` 改为接收请求上下文并引入 `src/public-url.js`，使对外基地址具备反向代理感知能力（见 §2.3）；另有构建期凭据脱敏（`REDACTIONS`）。

**业务逻辑未修改**（diff 仅 import 路径与上述补丁）。`app/` 与上游 standalone 在「本机直连」形态下行为一致；补丁只在反代场景下改变**展示用的基地址**，不影响任何请求路径与出网行为。

### 5.1 部署时要解决的一个硬约束

`startStandalone()` 第一行校验：`isLoopbackHost(host)` 为假直接抛 `TypeError`——**服务只能绑定 127.0.0.1 / ::1 / localhost**，这是上游刻意设计（免费额度按本机出口计量，绑可路由网卡等于把额度送给整个网段）。

推论：**反向代理必须与服务同网络命名空间**。本项目两种部署形态都遵循这一点：

- Docker：nginx 与 Node 同容器（`deploy/docker/`）；
- 裸机：nginx 与 Node 同主机，`proxy_pass http://127.0.0.1:18900`。

同时 nginx 必须改写两个 header（原理见 `deploy/nginx/ofm.conf` 注释）：`Host` 置为回环地址（管理端 structuralRejection 要求），`Origin`/`Referer` 置空不透传（管理端只认 `http://` 同源来源；置空即按「未提供」放行）。推理接口不校验这两个头，只认 Bearer Key。

---

## 6. 关键源码索引

| 文件 | 职责 |
|---|---|
| `cli.mjs` | 参数解析（--port/--data-dir/--no-refresh/--probe）、信号处理 |
| `service.mjs` | 组装 runtime/channels/management/eac，单实例锁，周期刷新调度 |
| `src/forward.js` | HTTP 服务：路由、Key 校验、SSE、tool_calls 重编号、端口顺延 |
| `src/http.js` | 上游错误分类（CODE 表）、SSE 读写、响应嗅探 |
| `src/anthropic.js` | Anthropic Messages 协议转换 |
| `src/kilo.js` | Kilo 免费池车道 |
| `src/adapter.js` + `src/catalog.js` | 匿名免费车道与清单解析 |
| `src/eac.js` + `src/eac-login.js` + `src/eac-user.js` | EAC 车道请求、登录轮询、用户授权文件 |
| `src/vault.js` + `vault-data.js` + `vault-anchor.js` | 密封车道：分片、HKDF、AES-256-GCM |
| `src/store.js` | JsonStore（settings/stats 原子写：临时文件 + rename） |
| `src/core/runtime.js` | 模型运行时：清单构建、探测、补全分发 |
| `channels/runtime.mjs` | 渠道 Worker 宿主（postMessage RPC、取消、统计） |
| `channels/worker.mjs` | Worker 入口：适配器注册、models/complete/rpc 分发 |
| `channels/business.mjs` | 13 家渠道适配器与账号池逻辑（上游构建产物） |
| `management.mjs` | 管理 API：会话、设置校验、密钥轮换、模型操作、静态资源（白名单读取） |
| `src/trust.js` | 回环判定与结构化的跨站防护（structuralRejection） |
| `src/public-url.js` | **本仓库新增**：反向代理感知的对外基地址推导（见 §2.3） |
