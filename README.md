# our-free-model-server

把 DeepSeek Harness 插件 **dsh-our-free-model** 重构为可直接部署在服务器上的独立服务：一个 **OpenAI 兼容的 LLM 网关**，聚合匿名免费通道、Kilo 免费池、EAC 协付通道与十三个账号渠道（CodeArts、CodeBuddy、WorkBuddy、LobsterAI、Qoder、TRAE、Cline、Loomy、Raccoon、MiniMax Code、ZCode、Gemini）。

- 运行时**零 npm 依赖**，只需要 Node.js 22.19+ / 24+
- 带完整网页管理台（渠道登录、账号池、模型清单、用量统计、服务设置）
- 支持 `/v1/chat/completions`、`/v1/responses`、`/v1/messages` 三套协议，流式与非流式
- 生产部署已加固：非 root + `cap_drop: ALL` + 只读根文件系统、限流、日志轮转、陈旧锁自愈、崩溃自动重启
- 上游：`Ebony-Vinyl/dsh-our-free-model`（MIT），分析报告见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

> ⚠️ 使用前请读 [docs/COMPLIANCE.md](docs/COMPLIANCE.md)：免费额度受各上游条款约束，Kilo 免费池的提示词可能被上游记录，勿传敏感内容。

> 🚀 **准备上生产环境**：先读 [docs/PRODUCTION.md](docs/PRODUCTION.md)。它逐项说明了本轮生产加固的改动、原因、预期效果、验证方式与回滚开关，并附目标服务器必测清单。

## 目录结构

```
ofm-server/
├── app/                     # 服务本体（自包含，勿改；由 tools/build-app.mjs 生成）
│   ├── cli.mjs              # 入口
│   ├── service.mjs          # 服务组装（回环绑定、单实例锁、周期刷新）
│   ├── management.mjs       # 管理 API + 网页控制台
│   ├── eac.mjs              # EAC 协付授权（GitHub OAuth）
│   ├── channels/            # 渠道 Worker（13 家适配器）
│   ├── src/                 # 核心：HTTP 网关、协议转换、车道、密封凭据
│   ├── web/                 # 预构建前端资源
│   └── vendor/              # Qoder 渠道 WASM
├── deploy/
│   ├── Dockerfile           # 单容器（Node + nginx 同容器，原因见下）
│   ├── docker-compose.yml   # 资源限额 / 只读根文件系统 / 日志轮转 / 健康检查
│   ├── docker/              # 容器内 nginx 配置、共享请求头、监督模式入口脚本
│   ├── nginx/               # 宿主机反代配置（ofm.conf / ofm-tls.conf）
│   ├── systemd/             # ofm.service + 周期健康检查 timer + journald / logrotate 配置
│   ├── scripts/             # 安装 / 健康检查 / 预检 / 诊断 / 清锁 / 就绪等待
│   └── env/ofm.env.example  # 全部环境变量（经代码逐条核对）
├── docs/
│   ├── ARCHITECTURE.md      # 逆向分析报告：功能/流程/鉴权/依赖
│   ├── COMPLIANCE.md        # 合规与隐私
│   └── PRODUCTION.md        # 生产加固说明与运维手册（上线前必读）
└── tools/
    ├── build-app.mjs        # 从上游重新生成 app/（升级用）
    └── verify-docs.sh       # 断言 docs/PRODUCTION.md 的声明与实际配置一致
```

`deploy/scripts/` 一览：

| 脚本 | 用途 | 何时用 |
|---|---|---|
| `install-bare.sh` | 裸机一键安装（建用户、装到 `/opt/ofm`、注册 systemd） | 首次部署 |
| `preflight.sh` | 启动前环境预检（权限/磁盘/内存/端口/锁状态） | 部署后、出问题前 |
| `healthcheck.sh` | 分层健康检查：`--quick`（默认）走 liveness+401+数据目录；`--full` 加模型清单与推理冒烟 | 日常巡检、监控接入 |
| `wait-ready.sh` | 就绪轮询，超时给出排查指引 | 由 systemd `ExecStartPost` 与容器入口调用 |
| `diagnostics.sh` | 只读诊断快照，**内置凭据脱敏自检**，输出可安全外发 | 事故第一动作 |
| `clear-stale-lock.sh` | 陈旧锁自动判定与恢复（区分陈旧残留与活跃实例） | 由入口 / `ExecStartPre` 自动调用 |

## 运行要求

| 项 | 要求 |
|---|---|
| Node.js | `^22.19.0` 或 `>=24.0.0`（Docker 镜像已含） |
| 网络 | 出网可达各上游（Kilo、Google、各渠道 API）；支持 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` |
| 磁盘 | 数据目录数百 MB，需持久化 |
| 内存 | 建议 ≥ 1GB；**必须**设 `NODE_OPTIONS=--max-old-space-size=1024`（原因见 [docs/PRODUCTION.md §2.1](docs/PRODUCTION.md)，不设会导致静默 OOM） |

**服务只绑定回环地址**（上游硬性约束，防免费额度被局域网白嫖）。因此反代必须与之同网络命名空间：Docker 形态把 nginx 放进同一容器；裸机形态 nginx 与服务同主机。

### 生产环境加固一览

`deploy/` 下的产物已按生产标准加固，逐项说明见 [docs/PRODUCTION.md](docs/PRODUCTION.md)：

| 维度 | 关键改动 |
|---|---|
| 环境与依赖 | 固定 Node 基线并在构建期校验；镜像内移除 npm；`.dockerignore` 排除凭据文件 |
| 性能与资源 | 显式 V8 堆上限（默认会申请 4.1GB，实测降至 1GB）；CPU/内存/PID/`nofile` 限额；`core: 0`（避免明文凭据进 core dump） |
| 安全与访问 | 非 root(10001) + `cap_drop: ALL` + `read_only: true`；三级限流；Host/Origin 重写；安全响应头；TLS + OCSP 装订；systemd 沙箱 |
| 日志与错误 | json-file/journald/logrotate 三套轮转；健康探测不污染访问日志；分层退出码契约；诊断输出脱敏 |
| 守护与重启 | 监督模式入口（替代 `exec nginx`，修掉"半边故障不可见"）；陈旧锁自愈；`Restart=always` + 防抖；优雅停机链路 |

## 快速开始

### 方式一：Docker（推荐，一条命令）

```bash
cd ofm-server
docker compose -f deploy/docker-compose.yml up -d --build
```

默认只发布到宿主机回环 `127.0.0.1:8080`。查看启动日志拿一次性管理链接：

```bash
docker logs ofm | grep 管理页面
```

对外暴露：把 `deploy/docker-compose.yml` 的端口改为 `"443:8080"` 并前置你自己的 TLS 终止，或直接用宿主机 nginx 反代 `http://127.0.0.1:8080`。

### 方式二：裸机 + systemd

```bash
sudo bash deploy/scripts/install-bare.sh
```

脚本自动完成：建 `ofm` 用户与 `/var/lib/ofm` 数据目录 → 安装到 `/opt/ofm` → 注册并启动 systemd 服务。然后配置反代：

```bash
sudo cp deploy/nginx/ofm-tls.conf /etc/nginx/conf.d/ofm.conf   # TLS 版；HTTP 版用 ofm.conf
sudo vi /etc/nginx/conf.d/ofm.conf    # 改 server_name 与证书路径
sudo nginx -t && sudo systemctl reload nginx
```

### 方式三：直接跑（开发/体验）

```bash
node app/cli.mjs --port 18900 --data-dir ./ofm-data
```

## 配置说明

所有配置都是**启动参数或环境变量**，没有配置文件需要手工编辑：

| 项 | 环境变量 / 参数 | 默认 | 说明 |
|---|---|---|---|
| 数据目录 | `OFM_HOME` / `--data-dir` | `~/.our-free-model` | API Key、账号凭据、账目都在这里，**必须持久化** |
| 端口 | `--port` | `18900` | 占用时自动顺延并记住；`0` = 系统分配 |
| 启动刷新 | `--no-refresh` | 开 | 跳过启动与周期刷新；手动刷新/推理仍可用 |
| 自动探测 | `--probe` | 关 | 每 15 分钟探测模型可用性（产生上游请求） |
| 出网代理 | `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY` | 无 | Gemini/Cline 渠道会读取 |
| 额外参数 | `OFM_EXTRA_ARGS`（Docker） | 空 | 如 `--no-refresh` |
| Node 堆 | `NODE_OPTIONS` | 默认 | 小服务器建议 `--max-old-space-size=1024` |

推理暂停/恢复、地区模型、断流恢复、输出上限、刷新间隔、自动探测——这些运行时设置在网页「服务设置」里改，存进 `settings.json`。

## 验证部署

```bash
# 0. 环境预检（权限 / 磁盘 / 内存 / 端口 / 锁状态）
bash deploy/scripts/preflight.sh /var/lib/ofm 18900

# 1. 一条命令全检（liveness / 401 拦截 / 模型清单 / 推理冒烟）
bash deploy/scripts/healthcheck.sh https://你的域名 /var/lib/ofm --full

# 2. 轻量检查（默认，适合接入监控，不做推理）
bash deploy/scripts/healthcheck.sh https://你的域名 /var/lib/ofm --quick

# 3. 出问题时：采集可外发的诊断包
bash deploy/scripts/diagnostics.sh /var/lib/ofm bare | tee /tmp/diag.txt
```

`healthcheck.sh` 退出码：`0` 正常 / `1` 异常 / `2` 用法或环境错误。容器与 systemd 均已内置周期健康检查，无需自行编排。

或手动：

```bash
# 1. 存活（免密钥）
curl https://你的域名/health
# → {"ok":true,"service":"our-free-model-standalone",...}

# 2. 取 Key（数据目录里）
python3 -c "import json;print(json.load(open('/var/lib/ofm/settings.json'))['forwardKey'])"

# 3. 模型清单（带 Key）
curl -H "Authorization: Bearer ofm-xxxx" https://你的域名/v1/models

# 4. 推理
curl -X POST https://你的域名/v1/chat/completions \
  -H "Authorization: Bearer ofm-xxxx" -H "Content-Type: application/json" \
  -d '{"model":"kilo-auto/free","messages":[{"role":"user","content":"say OK"}],"max_tokens":32}'
```

## 使用

任意 OpenAI 兼容客户端，把 base_url 指到本服务、api_key 填 `forwardKey` 即可：

```python
from openai import OpenAI
client = OpenAI(base_url="https://你的域名/v1", api_key="ofm-xxxx")
print(client.chat.completions.create(
    model="kilo-auto/free",
    messages=[{"role": "user", "content": "用一句话介绍量子纠缠"}],
).choices[0].message.content)
```

模型 ID 两类：

- 匿名/Kilo：`kilo-auto/free`、`ling-3.1-flash-free` 等（见 `/v1/models` 实时清单）
- 账号渠道：`<provider>/<model>`，如 `qoder/...`——需先在管理台登录对应渠道

### 管理页面

启动日志会打印一次性登录链接（`http://127.0.0.1:18900/#login=...`，10 分钟有效）：

```bash
# Docker
docker logs ofm | grep 管理页面
# systemd
journalctl -u ofm -n 20 --no-pager | grep 管理页面
```

链接过期后，用数据目录 `settings.json` 里的 `forwardKey` 直接登录。页面功能：概览、模型清单（搜索/筛选/单模型测试）、用量统计、免费账号渠道（13 家登录与账号池）、EAC 授权、服务设置、API 接入（查看/轮换密钥）。

渠道登录后模型才出现在 `/v1/models`；EAC 授权走管理页「EAC 协付渠道 → GitHub 授权」。

## 备份与升级

**备份 = 打包数据目录**（含明文凭据，**必须加密**后存放）：

```bash
docker stop ofm                                    # 停服保证一致性（或用文件系统快照）
tar czf ofm-data-$(date +%F).tar.gz -C /var/lib/ofm .
gpg -c ofm-data-$(date +%F).tar.gz                 # ← 含明文凭据与 API Key，不可明文保存
docker start ofm
```

**升级**：拉取新上游 → 重新生成 app → 重启，数据目录不动：

```bash
# 1. 更新上游源码（解压到 upstream/src/dsh-our-free-model-main）
# 2. 重新生成 app（纯机械提取，无业务改动）
node tools/build-app.mjs <上游路径> ./app
# 3. 重启
docker compose -f deploy/docker-compose.yml up -d --build   # Docker
sudo systemctl restart ofm                                   # 裸机
```

## 排错速查

| 现象 | 原因与解决 |
|---|---|
| 启动即退出：`数据目录已被服务占用` | 另一实例在跑。异常退出会留 `service.lock`，但入口与 systemd 会自动判定并清理陈旧锁；若仍失败，说明**确实有活跃实例**，先确认再手动删 |
| `管理页面 403 / 管理接口仅允许本机同源访问` | 反代没改 `Host` 或没剥离 `Origin`/`Referer`。对照 `deploy/nginx/ofm.conf` 的两行 `proxy_set_header`；容器形态请确认 `${OFM_PORT}` 已被替换（`docker exec ofm grep -c '\${' /tmp/ofm-proxy-headers.conf` 应为 0） |
| 反代 502 | 服务没起或端口变了（自动顺延后真实端口在 `settings.json` 的 `standalonePort`）。容器形态会在启动时**主动拦截**端口漂移并报错 |
| 流式卡住不吐字 | 反代开了缓冲。必须 `proxy_buffering off;`（本项目配置已含） |
| `401 missing or invalid API key` | Key 错；或轮换后客户端没更新。Key 在 `settings.json` 的 `forwardKey` |
| 模型报 `OpenCode's free tier can only be used from within OpenCode` | 上游指纹闸门拦截了部分匿名车道（上游策略）。换 `kilo-auto/free` 或登录账号渠道 |
| 渠道登录后没模型 | 该渠道未启用/模型被关：管理台「免费账号渠道」里检查供应商开关与模型开关 |
| Gemini/Cline 连不上 | 需要能访问 Google；配 `HTTPS_PROXY`，浏览器授权成功不代表服务端出口通 |
| 小内存服务器 OOM / 容器 exit 137 且无日志 | 未设 `NODE_OPTIONS=--max-old-space-size=1024`。V8 按宿主机物理内存推算堆上限（实测默认 4.1GB），不感知 cgroup |
| 容器启动报 `EROFS` / `EACCES` | 根文件系统只读，有写路径落在数据目录之外。定位该路径后补 `DSH_HOME`（默认落到 `~/.dsh` 是常见陷阱）或加 tmpfs；详见 [PRODUCTION.md §3.4](docs/PRODUCTION.md) |
| nginx 报 `unknown directive "http2"` | `http2 on;` 需要 nginx ≥ 1.25.1，Ubuntu 24.04 是 1.24。改用 `listen 443 ssl http2;` |
| nginx 报 `"log_format" directive is not allowed here` | `log_format` 只能写在 http 上下文，不能放 `server {}` 里 |
| 正常客户端大量 429 | 前面有 CDN/LB，`$remote_addr` 是代理 IP，所有人被算作同一个限流桶。配 `set_real_ip_from` + `real_ip_header`（见 [PRODUCTION.md §3.2](docs/PRODUCTION.md)） |
| 磁盘被日志写满 | 检查 `logging.options` 的 `max-size`/`max-file` 是否被其他 compose 覆盖文件吃掉 |
| 服务启动即退、日志见 `SIGSYS`/`mmap` 相关 | systemd 的 `MemoryDenyWriteExecute` 被设成了 `yes`；Node 的 JIT 与 Qoder WASM 需要可写可执行页，必须为 `no` |
| Windows 下 `EACCES` 而非 `EADDRINUSE` | 端口被 0.0.0.0 通配符监听或 `netsh interface portproxy` 占用，换端口或删规则 |

更多实现细节（请求流程、鉴权四层、依赖闭包）见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 安全清单（自托管必读）

- [ ] TLS 反代之后才对外（`deploy/nginx/ofm-tls.conf`）
- [ ] 安全组/防火墙限制来源，管理页面不要公网可达
- [ ] 数据目录备份**加密**（含明文凭据）
- [ ] 定期轮换 API Key（管理页「API 接入」）
- [ ] 确认端口只发布到回环（`docker port ofm` 应显示 `127.0.0.1:8080`）
- [ ] 若有 CDN/LB 前置：配置 `set_real_ip_from`，否则限流会误伤全部用户
- [ ] 跑一遍 [docs/PRODUCTION.md §7 目标服务器验证清单](docs/PRODUCTION.md)
- [ ] 读一遍 [docs/COMPLIANCE.md](docs/COMPLIANCE.md)，确认用法在各上游条款内

## 许可证

MIT（继承上游 `Ebony-Vinyl/dsh-our-free-model`）。`app/LICENSE`、`app/UPSTREAM.md` 为上游归属文件，请随分发保留。
