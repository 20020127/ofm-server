# 生产环境加固说明与运维手册

本文档记录本项目针对**服务器生产环境**的全部改动：每一处改动都给出「原问题 → 具体改动 → 原因 → 预期效果 → 如何验证 → 如何回滚」六段式说明，可以直接对照审查。

适用范围：`deploy/` 下的两套部署产物 —— Docker（`Dockerfile` + `docker-compose.yml`）与裸机（`systemd/ofm.service` + `scripts/install-bare.sh`）。两套的加固强度是对齐的。

阅读顺序建议：先看 §0 总览定位你关心的问题，再跳进对应维度；上线前必读 §7 与 §8。

---

## 0. 改动总览

### 0.1 修复的五个生产级缺陷

这五个是本轮加固的核心，都是「本地能跑、上服务器必出事」的类型：

| # | 缺陷 | 触发条件 | 原表现 | 修复位置 |
|---|---|---|---|---|
| 1 | **半边故障不可见**：`exec nginx` 让 Node 变成孤儿子进程 | Node 崩溃而 nginx 存活 | 容器不退、健康检查只是 `unhealthy`（Docker 不会因此重启）→ **服务永久 502，必须人工介入** | `docker/entrypoint.sh` 改监督模式 |
| 2 | **停止信号送不到 Node** | `docker stop` | SIGTERM 只到 PID1(nginx)，Node 被 SIGKILL → `service.lock` 残留 → 下次启动 `EEXIST` 失败 → **无限「重启-失败」循环** | `entrypoint.sh` 转发信号 + `stop_grace_period` + `ExecStartPre` 清锁 + tini |
| 3 | **日志无限增长** | 长期运行 | json-file 驱动默认**不轮转**，容器日志把磁盘写满 → 服务无法写盘 | compose `logging.options` + `systemd/journald-ofm.conf` + `ofm.logrotate` |
| 4 | **重启策略覆盖不全** | 进程退出码为 0 的异常退出 | `Restart=on-failure` 不重启 → 服务静默死掉 | `Restart=always` + `StartLimitBurst` 防抖 |
| 5 | **OOM 静默被杀** | 容器内存受限、宿主机内存大 | Node 按宿主机物理内存推算堆上限，撑爆 cgroup → **exit 137，日志里什么都没有** | 显式 `NODE_OPTIONS=--max-old-space-size` |

### 0.2 新增文件清单

| 文件 | 作用 |
|---|---|
| `deploy/docker/ofm-proxy-headers.conf` | 三个 location 共享的代理请求头片段（含关键的 Host/Origin 重写） |
| `deploy/scripts/clear-stale-lock.sh` | 陈旧锁自动判定与恢复，区分「陈旧」与「活跃实例」 |
| `deploy/scripts/wait-ready.sh` | 就绪轮询，超时给出可执行的排查指引 |
| `deploy/scripts/preflight.sh` | 启动前环境预检（权限、磁盘、内存、端口、锁） |
| `deploy/scripts/diagnostics.sh` | 只读诊断采集，内置凭据脱敏（实测不打印任何密钥内容） |
| `deploy/docker/nginx.conf` | 容器内 nginx：限流、SSE 免缓冲、日志治理 |
| `deploy/nginx/ofm.conf` / `ofm-tls.conf` | 裸机反代（HTTP / HTTPS + ACME + OCSP） |
| `deploy/systemd/ofm-healthcheck.{service,timer}` | 周期性深度健康检查（systemd 只看进程活着，看不到服务退化） |
| `deploy/systemd/journald-ofm.conf` | journald 容量与速率上限 |
| `deploy/systemd/ofm.logrotate` | 可选：文件日志轮转 |
| `deploy/env/ofm.env.example` | 完整环境变量示例（全部经代码核对） |
| `docs/PRODUCTION.md` | 本文档 |

---

## 1. 环境配置与依赖管理

### 1.1 固定 Node 基线并在构建期校验

**改动**：`Dockerfile` 用 `ARG NODE_IMAGE=node:22.19.0-alpine` + `FROM ${NODE_IMAGE}`，把基础镜像提到可参数化的位置；`install-bare.sh` 用 `node -e` 执行版本表达式校验，不满足直接失败。

**原因**：上游把运行时约束写成 `node: "^22.19.0 || >=24.0.0"`。`node:22-alpine` 这种漂移标签会随上游更新跳到新的小版本，构建不可复现；裸机上如果只有 18/20，会在运行到某个 WASM 或新 API 时才炸，而不是启动时就告诉你。

**预期效果**：同一份代码在任何时间构建出的运行时行为一致；不满足版本要求时**启动即失败并打印明确原因**，而不是运行中途出现难以定位的错误。

**验证**：
```bash
docker build --build-arg NODE_IMAGE=node:22.19.0-alpine -f deploy/Dockerfile . --target base
# 建议：docker inspect 拿到 digest 后把 ARG 默认值钉成 node:22.19.0-alpine@sha256:...
node -e "const[mj,mn]=process.versions.node.split('.').map(Number);process.exit(mj>22||(mj===22&&mn>=19)?0:1)" && echo "Node 版本满足"
```

**回滚**：改回 `FROM node:22-alpine`。不推荐——会失去可复现性。

### 1.2 运行时零 npm 依赖（已核实并固化）

**改动**：`Dockerfile` 显式删除 npm/npx：
```dockerfile
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
```

**原因**：本项目运行时**只用 Node 内置模块 + 一个 Qoder WASM**，没有任何 npm 依赖。但官方 Node 镜像自带完整 npm（约 70MB，且是历史上 CVE 的高发区）。

**预期效果**：镜像更小；攻击面缩小——容器内**不存在可用的包管理器**，即使应用被注入代码也无法 `npm install` 拉取恶意包；同时避免「有人误以为需要 npm ci」的部署混淆。

**验证**：
```bash
docker run --rm our-free-model-server:latest sh -c 'command -v npm || echo "npm 不存在 ✓"'
docker run --rm our-free-model-server:latest node -e 'console.log(Object.keys(require("/opt/ofm/app/package.json").dependencies||{}).length)'
# 期望输出 0
```

**回滚**：删除那行 `rm -rf`。无功能影响，只是放弃这项加固。

### 1.3 环境变量集中化与可核对

**改动**：`deploy/env/ofm.env.example` 重写，按「数据目录 / 端口 / 启动行为 / Node 运行时 / 出网代理 / 渠道开关 / 第三方凭据」七节组织，**变量清单是从 `app/` 里 grep 全部 `process.env.*` 逐条核对出来的**，并标注了内置默认值。

**原因**：上游有 60+ 个环境变量散落在 2.8MB 的 `business.mjs` 里，文档只说了一半。运维不知道 `DSH_HOME` 这个变量，就会踩 §3.4 的只读文件系统坑。

**预期效果**：任何人拿到这个文件就能知道存在哪些旋钮、默认值是多少、什么场景该调它。`OFM_HOME=/data` 与 compose 的 `environment` 保持一致，避免「env 文件写 `/var/lib/ofm`、compose 写 `/data`」这种两处打架。

**验证**：
```bash
# 重新核对变量清单（应与示例文件注释一致）
grep -rhoE "process\.env\.[A-Za-z_][A-Za-z0-9_]*" app/ | sed 's/process\.env\.//' | sort -u
```

**回滚**：无风险，纯文档性改动。

### 1.4 `env_file` 可选化

**改动**：
```yaml
env_file:
  - path: ./env/ofm.env
    required: false
```

**原因**：原写法在文件缺失时直接报错退出，导致「想先跑起来看看」的人第一步就被挡住。而首次部署时 `env` 文件本来就不该存在（里面是凭据）。

**预期效果**：不创建 `env` 文件也能直接 `docker compose up`；需要时再补。要求 Compose ≥ 2.24（旧版本降级写法见文件头注释）。

**验证**：`ls deploy/env/` 只有 `.example` 时执行 `docker compose -f deploy/docker-compose.yml config` 应无报错。

**回滚**：改回 `- ./env/ofm.env`，代价是必须先手工 `cp` 示例文件。

### 1.5 构建上下文最小化

**改动**：`deploy/.dockerignore` 排除 `deploy/env/ofm.env`、`deploy/env/*.local`、`**/.env`、`**/.env.*`（保留 `.env.example`）、`**/node_modules`、`**/*.log`、`.test-data`、`.data`、`tmp/`、`upstream`、`docs`、`tools`、`.git`、`*.md`（保留 `app/UPSTREAM.md`）。

**原因**：构建上下文会被完整发送给 Docker daemon。**最关键的是把凭据文件排除掉**——否则 `deploy/env/ofm.env` 会进镜像层，任何能 `docker history` / 拉到镜像的人都能读到你的 API Key 和渠道凭据。已核实此处没有误伤：`app/` 与 `deploy/docker/`、`deploy/scripts/` 未被排除。

**预期效果**：镜像层里不存在凭据；构建更快；`git` 历史不进镜像。

**验证**：
```bash
# 关键断言：镜像里搜不到凭据文件
docker run --rm our-free-model-server:latest sh -c 'ls /opt/ofm/env 2>/dev/null && echo "❌ 凭据文件进了镜像" || echo "✓ 未包含 env 目录"'
# 构建日志中 context 传输量应远小于 20MB
```

**回滚**：删除 `.dockerignore` 对应行。**强烈不建议**——会直接把凭据烤进镜像。

### 1.6 镜像元数据

**改动**：`ARG OFM_VERSION=1.0.0`、`ARG OFM_REVISION=unknown` → 写入 OCI label（`org.opencontainers.image.version` / `.revision` / `.base.name`）。

**原因**：「线上跑的是哪个版本」在事故复盘时是第一个要回答的问题。仅靠镜像 tag 不够（tag 会被覆盖）。

**预期效果**：`docker inspect` 一条命令就能确认版本与基础镜像。

**验证**：
```bash
docker inspect our-free-model-server:latest --format '{{json .Config.Labels}}' | tr ',' '\n'
```

**回滚**：无风险。

---

## 2. 性能与资源占用

### 2.1 显式设置 V8 堆上限（最重要的一项）

**改动**：`NODE_OPTIONS=--max-old-space-size=1024` 同时写入 compose `environment`、systemd `Environment=`、以及 env 示例。

**原因**：**V8 的默认堆上限按宿主机物理内存推算，完全不感知 cgroup 限额**。本机实测（Node 22.22.2 x64）：

| 配置 | `v8.getHeapStatistics().heap_size_limit` |
|---|---|
| 未设置 `NODE_OPTIONS` | **4144 MiB** |
| `--max-old-space-size=1024` | **1072 MiB** |

也就是说：一个 2GB 限额的容器跑在 64GB 的宿主机上，Node 会心安理得地申请到 4GB 堆，然后被内核 OOM Killer 直接杀掉 —— **表现为 exit 137，应用日志里一个字都没有**。

**预期效果**：内存占用有确定上界；`MemoryMax` / `deploy.resources.limits.memory` 能真正生效；OOM 从「神秘 137」变成「JS 堆溢出，有完整的 allocation 堆栈」。

**验证**：
```bash
# 实测堆上限（本机已验证）
NODE_OPTIONS=--max-old-space-size=1024 node -e "console.log((require('v8').getHeapStatistics().heap_size_limit/1048576).toFixed(0),'MiB')"
# → 1072 MiB

# 容器内验证
docker exec ofm node -e "console.log(process.env.NODE_OPTIONS)"

# 运行时观察真实占用（应稳定低于限额）
docker stats ofm --no-stream
```

**取值建议**：容器/服务内存限额的 50%~60%。限额 2GB → 设 1024；限额 1GB → 设 512（再多渠道可能不够，建议先升内存）。

**回滚**：去掉 `NODE_OPTIONS`。**不建议**——这等于主动接受随机 OOM。

### 2.2 资源限额与 PID 上限

**改动**：
```yaml
deploy: {resources: {limits: {cpus: "2.0", memory: 2g}}}
pids_limit: 512
ulimits: {nofile: {soft: 65536, hard: 65536}, core: {soft: 0, hard: 0}}
```

**原因**：
- **不设 CPU 限额**：单实例在流量尖峰时能吃满宿主机，拖垮同机的其他服务。
- **不设 PID 上限**：渠道 Worker 异常重启风暴会耗尽宿主机 PID 表（Docker 默认 4096，隔离性不足）。
- **`nofile` 必须在进程创建时给足**：nginx 的 `worker_rlimit_nofile` 指令**只能抬高 hard limit**，以非 root 运行时必然 `EPERM`。所以这个值只能在容器/unit 层面给（详见 §2.4）。
- **`core: 0`**：core dump 会把进程内存完整写到磁盘 —— 而本服务内存里有**明文渠道凭据和 API Key**。等于把凭据落盘成一个文件。

**预期效果**：单实例故障被限制在自身配额内；异常时不会产生含明文凭据的内存转储。

**验证**：
```bash
docker inspect ofm --format '{{.HostConfig.PidsLimit}} / {{.HostConfig.Ulimits}} / {{.HostConfig.Memory}}'
cat /proc/$(pgrep -f cli.mjs | head -1)/limits | grep -E "Max open files|Max core"
# 期望：65536 / 0
```

**回滚**：逐项删除。删 `core: 0` 请先确认你不会在事故现场拿到 core dump。

### 2.3 nginx 并发与限流参数

**改动**（`docker/nginx.conf` 与 `nginx/ofm.conf` 一致）：

| 参数 | 值 | 依据 |
|---|---|---|
| `worker_processes` | 2（仅容器） | 容器 CPU 限额 2.0；`auto` 会读宿主机 CPU 数，128 核宿主上的小容器会起出几十个 worker 白占内存。裸机形态不设置 —— 两份裸机配置是 `conf.d` 片段，主进程参数由发行版 `nginx.conf` 提供 |
| `worker_connections` | 2048（仅容器） | 同上；配合 `keepalive 32` 与 `limit_conn` 上限足够 |
| `upstream keepalive` | 32（三份配置一致） | 复用后端长连接，省掉每请求一次 TCP 握手；另有 `keepalive_timeout 60s` + `keepalive_requests 1000` |
| `limit_req_zone` | API `20r/s` / 管理 `10r/s` | 见 §3.2 |
| `client_max_body_size` | 32m | 容纳长上下文请求（base64 图片/长文档），渠道备份导入约 8MB |
| `proxy_read_timeout` | 3600s（流式 location） | LLM 长回答可能持续数十分钟，默认 60s 会半路掐断 |
| `gzip`（含 `gzip_types` / `gzip_proxied any`） | 三份配置一致 | 压缩预构建前端与管理页静态资源。**注意必须 `gzip_proxied any`**，否则走反代的响应不会被压缩 |
| `sendfile` / `tcp_nopush` / `tcp_nodelay` | 仅容器显式声明 | 裸机由发行版 `nginx.conf` 的默认值提供，`conf.d` 片段不重复声明 |
| `client_body_timeout` / `client_header_timeout` / `send_timeout` | 30s / 30s / 60s | 慢速攻击（Slowloris）防护；三份配置一致 |

**原因**：nginx 默认值是按「通用 Web 服务器」设计的，对 LLM 网关有两个致命不匹配 —— 长连接会被 `proxy_read_timeout 60s` 掐断；后端连接池不开启会让每请求都重新建连。

**预期效果**：长回答不中断；后端连接复用降低延迟与 TIME_WAIT 堆积；静态资源传输更快。

**验证**：
```bash
docker exec ofm nginx -t -c /tmp/nginx.generated.conf      # 语法
curl -N -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H 'Content-Type: application/json' \
  -d '{"model":"kilo-auto/free","messages":[{"role":"user","content":"写一篇 800 字作文"}],"stream":true}' \
  | head -20    # 应逐块吐字，而不是停顿后一次性输出
```

**回滚**：恢复各指令默认值。代价是长回答被截断。

### 2.4 为什么容器里**没有** `worker_rlimit_nofile`

这里记录一个**反向决策**，因为它很容易被误认为遗漏。

nginx 的 `worker_rlimit_nofile` 只能把文件描述符 hard limit **抬高**，且要求进程有 `CAP_SYS_RESOURCE`。我们的容器 `cap_drop: [ALL]` 且以非 root（uid 10001）运行 → 该指令必然以 `EPERM` 失败，nginx 启动失败。因此：

- **正确的做法**：在容器层面给（compose `ulimits.nofile`）或在 systemd 层面给（`LimitNOFILE=65536`）。
- **`docker/nginx.conf` 中的这一行已被删除**，并留有注释说明原因。

**验证**：`docker exec ofm nginx -t -c /tmp/nginx.generated.conf` 不出现 `setrlimit(RLIMIT_NOFILE)` 相关告警，且 `cat /proc/<nginx-pid>/limits` 显示 65536。

### 2.5 反代不在同容器会失效（架构性约束，勿改）

**保留说明**：上游 `app/src/trust.js` 的 `isLoopbackHost` 校验**硬性只允许服务绑定回环地址**（防止免费额度被局域网白嫖）。后果是：

- **Docker 形态**：容器网络的 DNAT 无法把发布端口的流量送达 `127.0.0.1` → **nginx 必须与 Node 同容器、同网络命名空间**。
- **裸机形态**：nginx 必须与服务同主机，且 `proxy_pass` 必须写 `127.0.0.1:<port>`，不能写 `localhost`（IPv6 解析到 `::1` 会因 Host 校验失败）。

这是上游设计红线，任何"优化"（拆成两个容器、加 sidecar）都会让服务直接不可用。

---

## 3. 安全性与访问控制

### 3.1 非 root 运行 + 能力全清

**改动**：
```dockerfile
RUN addgroup -g 10001 ofm && adduser -D -u 10001 -G ofm -h /data ofm
…
USER ofm
```
```yaml
security_opt: ["no-new-privileges:true"]
cap_drop: [ALL]
```

**原因**：容器逃逸类漏洞的绝大多数利用链都需要 root 或特定 capability 做起点。本服务只监听非特权端口（18900 / 8080），**不需要任何 capability** —— `cap_drop: ALL` 是零成本的加固。

**预期效果**：即使应用被 RCE，攻击者也只是容器内一个无权限的 `ofm` 用户，无法改系统文件、无法 `setuid`、无法抓包。

**验证**：
```bash
docker exec ofm id
# → uid=10001(ofm) gid=10001(ofm) groups=10001(ofm)
docker exec ofm sh -c 'capsh --print 2>/dev/null | head -3 || grep Cap /proc/self/status'
# → CapEff: 0000000000000000
docker exec ofm touch /etc/test 2>&1 | grep -q "Read-only\|Permission denied" && echo "✓ 无法写系统目录"
```

**回滚**：删 `cap_drop` / 改回 root。**强烈不建议**。

### 3.2 分层限流策略

**改动**：
```nginx
limit_req_zone $binary_remote_addr zone=ofm_api:10m rate=20r/s;
limit_req_zone $binary_remote_addr zone=ofm_admin:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=ofm_conn:10m;
limit_req_status 429;
limit_conn_status 429;
```
三个 location 分别 `burst=40`（API）/ `burst=20`（管理）/ `burst=30`（静态）。

**原因**：免费额度是**共享资源**，一个脚本小子就能打光。而且限流按 `$binary_remote_addr` 分桶，天然限制单 IP 的滥用；对 API 与静态资源用不同速率，避免「加载页面把 API 配额吃掉」。

**预期效果**：单 IP 突发被平滑（`burst` 允许瞬时抖动，不会误伤正常客户端），持续滥用被 429 拒绝。管理端限得更严 —— 管理接口涉及凭据操作。

**注意（生产必读）**：如果前面还有一层 CDN / LB / 云 WAF，`$remote_addr` 会变成那层的 IP，导致**所有用户被算成同一个桶**（正常用户也会被 429）。此时必须在 `ofm.conf` / `ofm-tls.conf` 中取消注释并**只信任真实的上游代理 IP**：
```nginx
set_real_ip_from 10.0.0.0/8;      # ← 改成你实际的上游代理网段
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

**验证**：
```bash
# 突发压测：前 40 个应通过，之后出现 429
for i in $(seq 1 80); do
  curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/health
done | sort | uniq -c
# 期望：大量 200 + 部分 429
```

**回滚**：注释掉 `limit_req` / `limit_conn` 指令。会失去滥用防护。

### 3.3 循环头重写（不做则管理台全废）

**改动**：`deploy/docker/ofm-proxy-headers.conf`（被容器内三个 location `include`）：
```nginx
proxy_http_version 1.1;
proxy_set_header Host              127.0.0.1:${OFM_PORT};
proxy_set_header Origin            "";
proxy_set_header Referer           "";
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Connection        "";
proxy_socket_keepalive on;
```

**原因**：上游管理端有两道自带的防 CSRF / 防 DNS-rebinding 校验，反代必须配合：

1. **`Host` 必须是 `127.0.0.1:<真实端口>`**。上游用 `authorityOf(req.headers.host,'http')` 做 `new URL()` 解析并比对端口。**端口必须匹配** —— 实测：`Host: 127.0.0.1`（无端口）会解析成默认端口 `80`，与监听端口不符 → 判定「非回环」→ **整个管理界面 403**。
2. **`Origin` / `Referer` 必须置空**。上游只接受 `http://` 同源。置空 = 不透传 = 按「未提供」放行。这也是为什么**不能用 `proxy_set_header Origin $http_origin`**。

推理接口不校验这两个头，所以客户端调用不受影响。

**踩坑记录（务必保留这条 sed）**：请求头片段里也有 `${OFM_PORT}` 占位符，因此 `entrypoint.sh` **必须同时对两个文件做替换**：
```bash
sed -e "s|\${OFM_PORT}|${OFM_PORT}|g" -e "s|\${OFM_PROXY_PORT}|${OFM_PROXY_PORT}|g" \
    /etc/nginx/ofm-proxy-headers.conf > /tmp/ofm-proxy-headers.conf
```
早期版本只替换了 `nginx.conf`，导致未替换的 `${OFM_PORT}` 字面量被当作 Host 发出 → `new URL()` 把 `${OFM_PORT}` 当端口解析为 `''`→`'80'` → 端口不匹配 → **整个管理 UI 403**。同理，三个 location 都必须 `include /tmp/ofm-proxy-headers.conf`（**已替换的副本**），而不是镜像内的原始路径。

**验证**：
```bash
# 1. 替换后不应残留占位符
docker exec ofm grep -c '\${' /tmp/ofm-proxy-headers.conf /tmp/nginx.generated.conf
# → 两个文件都应为 0

# 2. 管理接口应返回 401（需登录）而不是 403（Host 校验失败）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/api/management/overview
# → 401 ✓     若为 403 → Host/Origin 重写有问题

# 3. 结束到端验证：用一次性登录链接打开管理台，界面应正常渲染
docker logs ofm 2>&1 | grep 管理页面
```

**回滚**：直接删掉这些头会**立刻打断管理台**。回滚请改成「不透传」而非「透传原始值」。

### 3.4 只读根文件系统

**改动**：
```yaml
read_only: true
tmpfs:
  - /tmp:size=16m,mode=1777
  - /run:size=4m,mode=0755
  - /var/lib/nginx/tmp:size=64m,uid=10001,gid=10001,mode=0750
```

**原因**：让应用**只能往明确的卷写数据**。任何「写到了镜像层」的行为（缓存、临时文件、误配置的日志路径）都会立刻以 `EROFS` 暴露出来，而不是悄悄累积。

**改动前必须做的功课**（已逐条核实，这是本项能开启的前提）：列出全部落盘路径，确认它们**都在 `$OFM_HOME` 之下**：

| 路径 | 用途 |
|---|---|
| `settings.json` | 服务设置 + 下发的 API Key |
| `service.lock` | 单实例锁 |
| `channel-credentials.json` | 13 个渠道的登录凭据 |
| `eac-user.json` | EAC 授权 |
| `channel-pack/codearts-cache/` | CodeArts 能力缓存（可用 `OFM_CODEARTS_CACHE_DIR` 重定向） |
| `egress/mihomo.yaml`、`egress/mihomo.log` | 出网代理配置（若启用） |
| `<DSH_HOME>/cache/opencode-capabilities.json` | **渠道能力缓存** |
| `<DSH_HOME>/openai-gateway/api-key` | **渠道侧 API Key 缓存** |
| `/tmp/ofm-proxy-headers.conf`、`/tmp/nginx.generated.conf` | entrypoint 生成的 nginx 配置 |
| `/var/lib/nginx/tmp/{client_body,proxy}` | nginx 请求体与代理缓冲 |

**最后两行的 `DSH_HOME` 是隐藏陷阱**：它们默认解析到 `~/.dsh`，在只读根文件系统下**写失败**，而且错误被上游吞掉 —— 表现为「每次启动都重新拉一遍渠道能力目录」，容器重建后缓存丢失。因此 `entrypoint.sh` 与 `ofm.service` 都显式把 `DSH_HOME` 指向数据目录：
```bash
export DSH_HOME="${DSH_HOME:-$OFM_HOME}"
```

**预期效果**：容器内任何新增的写路径都会立即报错；所有持久状态集中在**一个卷**里，备份/迁移只需搬一个目录。

**验证**：
```bash
docker exec ofm sh -c 'touch /opt/ofm/x' 2>&1 | grep -q "Read-only" && echo "✓ 根文件系统只读"
docker exec ofm sh -c 'echo ok > /data/.wtest && rm /data/.wtest && echo "✓ 数据卷可写"'
docker exec ofm sh -c 'echo ok > /tmp/.wtest && rm /tmp/.wtest && echo "✓ tmpfs 可写"'
# 反向断言：重启后渠道能力缓存不应重复拉取
docker compose -f deploy/docker-compose.yml restart && docker logs ofm 2>&1 | grep -c "能力目录"
```

**回滚**：把 `read_only: true` 改成 `false`（或删掉该行）。若真遇到 `EROFS`，优先定位**是哪条路径**，再决定是加 tmpfs 还是补 `DSH_HOME`；实在无法定位时才临时关闭，并在本文档追加记录。

### 3.5 端口发布绑回环

**改动**：`ports: - "127.0.0.1:8080:8080"`。

**原因**：服务本身**不做 TLS**。若直接 `8080:8080` 发布到 `0.0.0.0`，流量会以明文 HTTP 承载 —— 包括**管理台的登录凭据和你所有渠道的 API Key**。云服务器的安全组默认策略经常不够严（尤其是内网互访场景）。

**预期效果**：默认配置下，服务在公网上**不可达**，必须先由运维显式决策（改端口映射 / 前置 TLS 反代），不存在"忘了配 TLS 就裸奔"的默认路径。

**验证**：
```bash
docker port ofm
# → 8080/tcp -> 127.0.0.1:8080     ← 必须是 127.0.0.1，不是 0.0.0.0
ss -tlnp | grep 8080
# 从另一台机器：curl http://<公网IP>:8080/health 应连接被拒
```

**回滚**：改成 `"8080:8080"` —— 但请**先**把 TLS 反代配好。

### 3.6 前端安全响应头

**改动**（两个 nginx 配置均含）：
```nginx
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy no-referrer always;
server_tokens off;
```

**原因**：管理台是本服务唯一的浏览器界面，且持有全部凭据。
- `X-Frame-Options: DENY`：**关键** —— 防止把管理台嵌进 iframe 做点击劫持。
- `Referrer-Policy: no-referrer`：管理台 URL 里带一次性登录 token（`#login=...`），防止它被 Referer 头泄漏到第三方。
- `nosniff`：阻止 MIME 类型嗅探导致的脚本执行。
- `server_tokens off`：不暴露 nginx 版本，减少被针对性扫描。

**预期效果**：常见的前端侧攻击面被关闭；响应头不泄漏版本信息。

**验证**：
```bash
curl -sI https://你的域名/health | grep -iE "x-content-type|x-frame|referrer|server"
# → 三个安全头齐全；Server 头不含版本号
# 在线复核：https://securityheaders.com
```

**回滚**：删除对应 `add_header`。无功能影响，纯加固。

### 3.7 TLS 配置要点

**改动**（`deploy/nginx/ofm-tls.conf`）：

| 项 | 值 / 做法 | 原因 |
|---|---|---|
| `listen 443 ssl http2;` | **刻意用旧写法** | `http2 on;` 独立指令只在 **nginx ≥ 1.25.1** 存在；Ubuntu 24.04 仓库是 1.24 → 用新写法会 `unknown directive` 启动失败。旧写法在 1.25+ 只是打印弃用警告，**优先级是"能启动"** |
| `ssl_protocols TLSv1.2 TLSv1.3` | 显式指定 | 禁用 TLSv1.0/1.1 |
| `ssl_ciphers` ECDHE+AEAD 白名单 | 显式指定 | 排除 CBC 与不提供前向保密的套件 |
| `ssl_session_tickets off` | 关闭 | 会话票据会削弱前向保密（密钥泄露可解密历史流量） |
| `ssl_stapling on` + `ssl_trusted_certificate chain.pem` | 开 | OCSP 装订，客户端不必再回查 CA，握手更快且不泄漏访问行为 |
| `add_header Strict-Transport-Security "max-age=31536000"` | **不带 `includeSubDomains` / `preload`** | 加了会把**整个域名及其所有子域**锁死在 HTTPS 一年，且浏览器预加载列表难以撤销。除非你确定全部子域都已支持 HTTPS |

**预期效果**：A 级以上的 TLS 评级；前向保密；OCSP 装订。

**验证**：
```bash
nginx -t
curl -sI https://你的域名/health | grep -i strict-transport
openssl s_client -connect 你的域名:443 -tls1_1 </dev/null 2>&1 | grep -i "no protocols\|alert"  # TLS1.1 应被拒
# 在线复核：https://www.ssllabs.com/ssltest/
```

**回滚**：整体换回 `deploy/nginx/ofm.conf`（纯 HTTP）并前置你自己的 TLS 终止。

### 3.8 systemd 沙箱

**改动**（`ofm.service` 的加固指令）：
```
NoNewPrivileges, PrivateTmp, PrivateDevices, ProtectSystem=strict, ProtectHome,
ProtectKernelLogs/Clock/Hostname, RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK,
SystemCallArchitectures=native, ReadWritePaths=/var/lib/ofm,
CapabilityBoundingSet=（空）, AmbientCapabilities=（空）, UMask=0077
```

**原因**：`ProtectSystem=strict` 把整个文件系统挂成只读（除 `/dev`/`/proc`/`/sys`），再用 `ReadWritePaths` 只开出数据目录 —— 与容器的 `read_only: true` 是**同一思路，加固强度对齐**。`UMask=0077` 保证服务新建的文件（凭据！）默认只有属主可读。

**两个刻意的例外，都写了注释说明原因，改动前务必读**：

1. **`MemoryDenyWriteExecute=false`（必须显式关闭）**：该指令默认为 `false`，但很多"systemd 加固模板"会打开它。**打开会让 Node 直接无法启动** —— V8 的 JIT 需要把生成的可执行页标记为可执行，Qoder 渠道的 WASM 更是需要 W^X。这里显式写出 `false` 是为了防止后来者"顺手加固"。
2. **`ProtectProc=invisible` 与 `SystemCallFilter=@system-service` 未启用**：前者会隐藏 `/proc/<pid>`，而我们的陈旧锁判定**依赖 `/proc/<pid>` 存在性**（见 §5.2）；后者白名单可能拦截 Node 用到的系统调用。

**预期效果**：单进程被关进一个"除数据目录外全只读、零 capability、私有临时目录"的沙箱。

**验证**：
```bash
systemd-analyze verify deploy/systemd/ofm.service      # 语法（需 systemd ≥ 229）
systemd-analyze security ofm.service                   # 暴露面评分
systemctl show ofm -p ProtectSystem -p NoNewPrivileges -p CapabilityBoundingSet
ls -l /var/lib/ofm/settings.json && stat -c '%a' /var/lib/ofm/settings.json   # 应为 600
```

**回滚**：逐条注释掉可疑指令并 `systemctl daemon-reload`。回滚 `MemoryDenyWriteExecute` 是**唯一会导致服务完全起不来**的一项——若发现服务启动即退出且日志提到 `SIGSYS`/`mmap`，先查这条。

---

## 4. 日志与错误处理

### 4.1 日志轮转（三套并存，按部署方式选）

**问题**：Docker 的 `json-file` 日志驱动**默认不轮转**。长期运行的服务会把宿主机磁盘写满，然后连自己的日志都写不进去。

**改动**：

| 部署方式 | 位置 | 关键参数 |
|---|---|---|
| Docker | `docker-compose.yml` → `logging` | `max-size: 20m` × `max-file: 5` = **单容器上限 100MB** |
| 裸机（journald） | `deploy/systemd/journald-ofm.conf` | `SystemMaxUse=500M`、`SystemKeepFree=1G`、`SystemMaxFileSize=50M`、`MaxRetentionSec=2week`、`RateLimitBurst=20000` |
| 裸机（文件日志，可选） | `deploy/systemd/ofm.logrotate` | daily / rotate 14 / `copytruncate` / `maxsize 100M` / `create 0640 ofm ofm` |

**关键设计点**：

- `SystemKeepFree=1G` 比 `SystemMaxUse=500M` 更重要 —— 它保证 journald **主动给系统留出 1GB 自由空间**，避免"日志把根分区写满导致服务无法启动"。
- `RateLimitBurst=20000`：默认值（1000/30s）在启动时渠道刷新会打出大量日志，**会被 journald 静默丢弃**，事故复盘时最需要的日志恰好缺失。
- `copytruncate` 而非 `create`：服务不响应 `SIGHUP`（上游只处理 SIGINT/SIGTERM），**不能用 `reload` 方式轮转**。`copytruncate` 原地截断，不需要服务重启。
- `ofm.logrotate` 只针对 `/var/log/ofm/*.log`，**刻意不碰 nginx 日志** —— 发行版的 nginx 包自带 logrotate 规则，重复配置会导致日志丢条目。

**预期效果**：磁盘占用有确定上界；日志按时间与大小双阈值轮转；关键启动日志不被速率限制吞掉。

**验证**：
```bash
# Docker
docker inspect ofm --format '{{json .HostConfig.LogConfig}}'
docker exec ofm du -sh /var/lib/docker 2>/dev/null || ls -lh $(docker inspect ofm --format '{{.LogPath}}')
# → 应小于 20MB

# journald
journalctl --disk-usage
systemctl show systemd-journald -p SystemMaxUse
journalctl -u ofm --since "1 hour ago" | wc -l     # 启动日志条目应完整，无 "Suppressed"

# 可选：logrotate 空跑
logrotate -d /etc/logrotate.d/ofm
```

**回滚**：删除对应配置。回滚 journald drop-in 后记得 `systemctl restart systemd-journald`。

### 4.2 日志输出到 stdout/stderr（容器规范）

**改动**：`docker/nginx.conf` 中 `error_log /dev/stderr warn;`、`access_log /dev/stdout ...`，**不写文件**。

**原因**：容器里往文件写日志等于写进容器的可写层 —— 容器删了日志就没了，且 `docker logs` 看不到。标准做法是全部走 stdout/stderr，交给容器运行时统一收集。

同时加了 `map $request_uri $ofm_loggable`，**把 `/health` 从访问日志里排除**：
```nginx
map $request_uri $ofm_loggable { default 1; /health 0; }
access_log /dev/stdout ofm if=$ofm_loggable;
```

**原因**：健康检查每 30 秒一次，一天约 2880 条纯噪声 —— 会把真正有用的请求日志淹没在轮转窗口之外。

**预期效果**：`docker logs` 能看到全部日志；健康探测不污染访问日志；配合 §4.1 的轮转上限，日志不会撑爆磁盘。

**验证**：
```bash
docker logs --tail 20 ofm            # 应有应用日志与访问日志
docker logs ofm 2>&1 | grep -c "/health"    # 期望接近 0（启动阶段少数几条）
docker logs ofm 2>&1 | grep -c "GET /v1/models"   # 推理请求应可见
```

**回滚**：改回文件路径（同时会失去 `docker logs` 能力）。

### 4.3 访问日志格式

**改动**：
```nginx
log_format ofm '$remote_addr - $remote_user [$time_local] "$request" '
               '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
               'rt=$request_time urt=$upstream_response_time';
```

**注意**：`log_format` 是 **http 上下文指令**，只能写在 http 块内。本项目在 `nginx/ofm.conf` 与 `ofm-tls.conf` 里都**刻意放在 `upstream` 之上**的 http 区域 —— 早期版本误放进 `server {}` 会让 `nginx -t` 直接失败（`"log_format" directive is not allowed here`）。

**预期效果**：`rt` 与 `urt` 分离，可以区分「慢在自己」还是「慢在上游」——排查 LLM 延时问题的关键字段。

**验证**：
```bash
nginx -t          # 必须无 "directive is not allowed here"
tail -5 /var/log/nginx/ofm-access.log
```

### 4.4 分层错误处理与退出码契约

**改动**（`entrypoint.sh` 头部明确写出并实现）：
```
退出码约定：
  0  —— 收到 SIGTERM/SIGINT 后优雅停止（docker stop / systemctl stop）
  ≠0 —— 服务或反代异常退出，原样传播服务自身退出码
        （便于识别 137=OOM、1=启动失败等）
```

**原因**：编排层（Docker `restart` / systemd `Restart`）**只看退出码**。若把"优雅停止"和"崩溃"都退出成非零，正常维护时的 `docker stop` 会被计入失败并触发告警风暴；反之，若崩溃也退出 0，重启策略不会生效。

**实现要点**（每一处都对应一个已踩的坑）：

1. **`set -uo pipefail` 而不是 `set -euo`**：需要自己控制每步的失败分支，`-e` 会让 `kill -0` 这类"用返回码表达状态"的命令直接中止脚本。
2. **`STOPPING` 标志位**：`wait -n` 在**收到已 trap 的信号但没有子进程死亡**时也会返回 `128+signo`（实测返回 143，子进程仍存活）。不做这个判断，一次正常的 `docker stop` 会被误报成"nginx 已退出"并以 143 结束 —— **运维会被彻底误导**。
3. **启动阶段被打断 ≠ 启动失败**：就绪轮询里也检查 `STOPPING`，收到停止信号立即 `exit 0`，而不是等满 `OFM_STARTUP_TIMEOUT` 再报错。
4. **反代不该自行退出**：若退出的是 nginx 且 `RC=0`，也强制转成 `1` —— 非零退出才能触发重启策略。
5. **启动失败的排查指引直接打印**：不只说"失败了"，而是给出三个方向 + `rc=137` 的 OOM 提示。

**预期效果**：编排层能准确区分「该重启」和「该告警但别重启」；事故时的第一手信息（退出码）不丢失。

**验证**：
```bash
# 优雅停止应得 0
docker stop ofm && docker inspect ofm --format '{{.State.ExitCode}}'   # → 0

# 服务崩溃应得非零且容器真的退出（而不是只剩 nginx 活着）
docker exec ofm pkill -f cli.mjs
docker inspect ofm --format '{{.State.ExitCode}} {{.State.Status}}'    # → 非 0, exited

# 就绪超时应正确报错
docker run --rm -e OFM_STARTUP_TIMEOUT=3 -e OFM_PORT=1 our-free-model-server:latest; echo "rc=$?"
```

### 4.5 诊断采集内置脱敏

**改动**：`deploy/scripts/diagnostics.sh` —— 只读快照（进程/端口/锁归属/配置/资源/日志尾部），采集完成后对**整份快照**做自动泄漏自检并给出结论与退出码。

**原因**：事故现场最需要的动作是"把所有状态导出来"，但数据目录里全是明文凭据。如果诊断脚本直接把 `settings.json`、`channel-credentials.json` 打出来，这些内容就进了工单系统、聊天记录、邮件。

两层防护：

1. **设计上不打印凭据**：脚本只列数据目录的**文件名与权限**，从不读取 `settings.json` / `channel-credentials.json` / `eac-user.json` 的内容。锁文件是例外 —— 其内容仅 `{pid, product}`，无凭据。
2. **采集后兜底自检**：日志、环境变量等仍可能夹带敏感内容（例如服务启动日志里的**一次性管理登录链接**）。因此脚本把全部输出先写入临时文件，再对整份快照扫描，结尾打印明确结论：

| 级别 | 模式 | 处理 |
|---|---|---|
| 高危 | `forwardKey`、`client_secret`、`client_id`、`access_key`、`refreshToken`、`"password"`、JWT（`eyJ….…`）、`sk-…`、**`ofm-<32位base64url>`**（本服务自己的 API Key） | `exit 1` + **禁止外发**，给出如何删除对应行 |
| 提示 | `#login=`（服务启动日志里的一次性管理链接，约 10 分钟有效） | 打印行号，建议打码但不算失败 |
| 干净 | — | `exit 0` + "可安全外发" |

加入 `ofm-…` 这一条是因为排查过 `generateKey()`：本服务的 Key 是 `ofm-` + 24 字节 base64url（共 36 字符）。而 `ofm-user` / `ofm-timestamp` / `ofm-signature` 是协议头名，长度门槛 `{20,}` 使它们不会误报。

**为什么退出码很重要**：`exit 1` 让"能不能外发"不再依赖执行者的自觉，也让这一步可以被脚本或流程卡住。

**预期效果**：一条命令产出可安全外发的诊断包，且有机器可校验的结论。

**验证**（均已实测）：直接**从脚本里提取真实正则**再跑样本，避免测的是副本。
```bash
# 1) 对真实实例运行：应得到"未发现高危凭据"，exit 0
bash deploy/scripts/diagnostics.sh /var/lib/ofm bare | tee /tmp/diag.txt
echo "rc=${PIPESTATUS[0]}"          # 期望 0

# 2) 取出脚本内的真实正则做正负样本测试
PAT=$(sed -n "s/^PAT_HIGH='\(.*\)'$/\1/p" deploy/scripts/diagnostics.sh)
printf '%s' '{"forwardKey":"ofm-EXAMPLEKEYEXAMPLEKEYEXAMPLEKEY00"}' | grep -qE "$PAT" \
  && echo "✓ 自检能命中" || echo "✗ 自检漏判"
```

> 下表样本值均为**自证是占位符**的形式（含 `EXAMPLE` / `YOUR-...`）。实测用的就是这些值，
> 刻意不写高熵的假 Key —— 公开仓库里放形似真凭据的字符串，会被读者或扫描器误认为泄漏。

实测结果（11 个样本，6 命中 / 5 正确放行）：

| 类别 | 样本 | 结果 |
|---|---|---|
| 本服务 Key | `{"forwardKey":"ofm-EXAMPLEKEYEXAMPLEKEYEXAMPLEKEY00"}` | 命中 ✓ |
| 本服务 Key | `Bearer ofm-EXAMPLEKEYEXAMPLEKEYEXAMPLEKEY00` | 命中 ✓ |
| 第三方 Key | `sk-EXAMPLE-EXAMPLE-EXAMPLE-EXAMPLE` | 命中 ✓ |
| JWT | `eyJEXAMPLEHEADER.eyJEXAMPLEPAYLOAD` | 命中 ✓ |
| Google 凭据 | `"client_secret":"YOUR-GOOGLE-CLIENT-SECRET"` | 命中 ✓ |
| OAuth 刷新令牌 | `"refreshToken":"YOUR-REFRESH-TOKEN"` | 命中 ✓ |
| 环境变量名（非值） | `OFM_LOOMY_ACCESS_KEY_ID` | 正确放行 ✓ |
| 协议头名 | `ofm-user: ofm-signature: ofm-timestamp:` | 正确放行 ✓ |
| 正常配置行 | `NODE_OPTIONS : --max-old-space-size=1024` | 正确放行 ✓ |
| 锁文件内容 | `锁文件 : 存在 -> {"pid":22716,"product":"our-free-model-standalone"}` | 正确放行 ✓ |
| 无关文本 | `dsl-2.1.0  key=value` | 正确放行 ✓ |

**另一个实测确认的设计意图**：往数据目录里放一个明文含 Key 的文件（`LOOSE-LEAK.json`），诊断输出里**该内容出现 0 次** —— 因为脚本只列文件名与权限、从不读内容。这是第一层防护生效的证据。

**回滚**：无风险（只读脚本）。若自检误报过多影响使用，可放宽 `PAT_HIGH`；但**不要直接删掉自检段** —— 它是防止未来维护引入泄漏的最后一道闸。

### 4.6 周期性深度健康检查

**改动**：`ofm-healthcheck.service`（oneshot）+ `ofm-healthcheck.timer`（`OnBootSec=3min`、`OnUnitActiveSec=5min`、`RandomizedDelaySec=20s`）。

**原因**：systemd 只关心"进程还在不在"。而本服务有一个典型的**退化状态**：进程活着、端口听着，但**数据目录不可写**或**API Key 丢失**（例如卷挂载失败、磁盘满）—— 此时 systemd 认为一切正常，服务却完全不可用。

`RandomizedDelaySec=20s` 避免所有机器在同一秒做检查（对上游友好，也避免自己打自己）。

**预期效果**：退化状态在 5 分钟内被发现并记录到 journal；即使不接告警系统，`journalctl -u ofm-healthcheck` 也有完整历史。

**验证**：
```bash
systemctl list-timers ofm-healthcheck.timer
systemctl start ofm-healthcheck.service && journalctl -u ofm-healthcheck -n 20 --no-pager
# 手工制造退化：chmod 500 /var/lib/ofm 后再跑，应报 unhealthy
```

**回滚**：`systemctl disable --now ofm-healthcheck.timer`。

---

## 5. 进程守护与自动重启

### 5.1 监督模式入口（替代 `exec nginx`）

**改动**：`entrypoint.sh` 从 `exec nginx` 改为**监督循环**：

```bash
node cli.mjs --port "$OFM_PORT" --data-dir "$OFM_HOME" $OFM_EXTRA_ARGS &
OFM_PID=$!
trap shutdown TERM INT
# …就绪等待、端口顺延检测、生成并启动 nginx…
wait -n || RC=$?
```

**原因**（这是本轮最重要的一处修复）：原实现用 `exec nginx` 收尾，导致两个已确认的生产事故：

1. **Node 崩溃时 nginx 仍存活** → 容器不退出 → Docker 的健康检查只把它标成 `unhealthy`，但 `unhealthy` **不会触发重启策略** → 服务永久 502，只能人工介入。
2. **`docker stop` 的 SIGTERM 只送到 PID1(nginx)** → Node 收不到信号 → 被 SIGKILL → `service.lock` 残留 → 下次启动 `EEXIST` 失败 → 容器陷入 **"反复重启-反复失败"** 的死循环。

**预期效果**：任一子进程退出，容器就带着对应退出码退出 → `restart: unless-stopped` 真正生效 → 故障自愈。同时信号能正确转达给 Node，触发它的优雅退出与锁清理。

**验证**：
```bash
# 1) 杀 Node，容器应退出（而不是只剩 nginx 活着）
docker exec ofm pkill -f cli.mjs
sleep 5 && docker inspect ofm --format '{{.State.Status}} {{.State.ExitCode}}'
# → exited / 非 0（然后再被 restart 策略拉起来）

# 2) 杀 nginx，容器也应退出
docker exec ofm sh -c 'kill -QUIT $(cat /run/nginx.pid 2>/dev/null || pgrep -f "nginx: master" | head -1)'
sleep 5 && docker inspect ofm --format '{{.State.Status}}'
```

**回滚**：改回 `exec nginx`。**这是明确的退化**，会同时恢复上述两个事故。

### 5.2 陈旧锁自动恢复（含一个反直觉的坑）

**改动**：`deploy/scripts/clear-stale-lock.sh`，在 `entrypoint.sh` 第 0 步与 systemd `ExecStartPre` 中调用。判定表：

| 锁中 PID | 进程状态 | 命令 | 动作 |
|---|---|---|---|
| 无锁文件 | — | — | 静默通过 |
| 有 PID | `/proc/<pid>` 不存在**且** `kill -0` 失败 | — | **陈旧 → 删除锁** |
| 有 PID | 存活，且 cmdline 匹配 `*cli.mjs*`/`*our-free-model*` | — | **活跃 → 拒绝启动，exit 1** |
| 有 PID | 存活，但是别的进程 | — | PID 被复用 → 删除锁 |
| 有 PID | 存活，但 cmdline 读不到 | — | 无法判定 → 保守拒绝，exit 1 |
| PID 字段不可读 | — | — | 删除锁（无 pid 无法保护） |
| — | — | `--force` | 跳过判定直接删锁 |

**原因**：上游用 `O_EXCL` 创建 `service.lock`（`fs.openSync(lockFile,'wx',0o600)`，内容 `{pid, product}`），**只在优雅退出时删除**。任何非优雅退出（SIGKILL、断电、OOM）都会留下它，之后每次启动都 `EEXIST` 失败。

**这里有一个实测发现的真实缺陷，务必保留**：早期实现只用 `kill -0 "$PID"` 判活。但在 **`kill -0` 对"属于别的用户的存活进程"返回非零（EPERM）** 的场景下，会把**活跃实例误判为已死**，进而删掉它的锁 —— 造成两个实例并行、账目错乱。

**修复**：改用**两个判据取「或」** —— `/proc/<pid>` 存在（权威）**或** `kill -0` 成功（兜底）。

这个方向性是刻意的：取「或」只会把 dead 误判成 alive（结果是**拒绝删锁、要求人工介入**），**绝不会把 alive 误判成 dead**。与脚本「宁可拒绝启动，也不并发双实例」的原则一致 —— 误判的代价从"数据错乱"降到"多看一眼"。

**已知局限（部署前确认，见 §7）**：`/proc` 若以 `hidepid=1/2` 挂载则跨用户不可见；非 Linux 平台的 `/proc` 可能是残缺模拟（实测 MSYS 只索引自己的 PID，不含原生 Windows 进程）。这两种情况下判据一会漏判、脚本退化为清理策略。本项目两种部署形态均不受影响：容器内入口与服务同为 uid 10001；systemd 单元的 `User=ofm` 使 `ExecStartPre` 与服务同用户。

**实测记录**（本机，真实运行实例）：

| 场景 | 结果 |
|---|---|
| 锁指向**已死** PID（999999） | 正确识别为陈旧 → 删锁，exit 0 ✓ |
| 锁文件无 `pid` 字段 | 正确删锁，exit 0 ✓ |
| 无锁文件 | 静默 exit 0 ✓ |
| `--force` | 跳过判定删锁，exit 0 ✓ |
| 缺参数 | exit 2 并打印用法 ✓ |
| 锁指向**存活**实例 | ⚠️ **本机无法验证** —— 见下 |

实测输出：
```
[lock] 锁中 pid=999999 未能找到对应进程（/proc 无此目录，kill -0 亦失败）→ 陈旧残留，移除锁
```

**「活跃实例保护」这一条本机测不出来，必须到 Linux 上验证**：Windows/MSYS 环境下 `/proc` 只索引 MSYS 自身 PID，而 `service.lock` 里存的是 Node 报出的**原生 Windows PID**，于是 `/proc/<pid>` 不存在；同一 PID 上 `kill -0` 也报 `No such process`（ESRCH，不是 EPERM）。两个判据同时假阴性。这是 MSYS 的环境特性，**不代表 Linux 上的行为** —— Linux 的 `/proc/<pid>` 对进程存在性是权威的，这正是该设计成立的前提。因此这一项已列入 §7 必测清单（第 8 项）。

**预期效果**：断电/OOM/`docker kill` 之后的**首次启动即可自动恢复**，不再需要人工删锁；同时不会误伤真正在跑的实例。

**验证**：
```bash
# 1) 陈旧锁：应自动清理（本机已验证）
echo '{"pid":999999,"product":"our-free-model-standalone"}' > /var/lib/ofm/service.lock
bash deploy/scripts/clear-stale-lock.sh /var/lib/ofm; echo "rc=$?"
# → rc=0，锁被删除

# 2) 活跃实例保护：必须在 Linux 上验证（本机 MSYS 不可靠）
node app/cli.mjs --port 18988 --data-dir /tmp/oft --no-refresh &
sleep 10
echo "{\"pid\":$!,\"product\":\"our-free-model-standalone\"}" > /tmp/oft/service.lock
bash deploy/scripts/clear-stale-lock.sh /tmp/oft; echo "rc=$?"
# → 期望 rc=1，锁保留，打印"检测到活跃服务实例"
ls /tmp/oft/service.lock && echo "锁保留 ✓"
```

**回滚**：删除调用。代价是回到"必须人工删锁"。

### 5.3 优雅停机链路

**改动**：三处协同，缺一不可：

| 层次 | 配置 | 作用 |
|---|---|---|
| PID1 | 镜像 `ENTRYPOINT ["/sbin/tini", "--", ...]` | 作为 PID1 正确转发信号、回收僵尸进程 |
| 容器 | `stop_signal: SIGTERM` + `stop_grace_period: 40s` | 给足优雅退出时间（**必须 > `OFM_STOP_TIMEOUT`**） |
| entrypoint | `trap shutdown TERM INT`；`kill -TERM` 给 Node（触发其锁清理）、`kill -QUIT` 给 nginx；并有 `( sleep $OFM_STOP_TIMEOUT; kill -KILL ) & disown` 兜底 | 转发信号 + 防止卡死 |
| systemd | `KillSignal=SIGTERM`、`KillMode=mixed`、`TimeoutStopSec=30s` | 同上 |

**为什么需要"先优雅后强杀"的兜底**：服务里可能有**卡住的流式长连接**。若它忽略 SIGTERM，容器会一直挂到 `stop_grace_period` 用尽然后被 `SIGKILL` —— **又回到"残留锁"**。所以 entrypoint 自己在 `OFM_STOP_TIMEOUT` 后补一刀。

**为什么 `stop_grace_period` 必须大于 `OFM_STOP_TIMEOUT`**：当前是 40s > 25s，留 15s 给 nginx 退出与日志刷盘。**如果反了**，Docker 会先 SIGKILL 整个容器，Node 根本来不及清理锁。

**⚠️ 容器里刻意没有 `init: true`**：镜像的 `ENTRYPOINT` 已经内置 tini 作 PID1。如果靠运行时注入 init，**"直接 `docker run`"的用户会丢掉这层保护** —— 把保障放在镜像里比放在编排配置里更可靠。

**预期效果**：`docker stop` / `systemctl stop` 后**锁被正确清理**，下次启动不需要清锁流程介入。

**验证**：
```bash
docker stop ofm
ls /var/lib/ofm/service.lock 2>/dev/null && echo "❌ 锁残留" || echo "✓ 锁已清理"
docker start ofm && sleep 15 && docker exec ofm cat /var/lib/ofm/service.lock   # 应有新锁
docker inspect ofm --format '{{.State.ExitCode}}'     # 优雅停止 → 0
```

**回滚**：不要回滚。若需缩短等待，调小 `OFM_STOP_TIMEOUT` 并同步调小 `stop_grace_period`（保持 15s 余量）。

### 5.4 `Restart=always` 而非 `on-failure`

**改动**：
```ini
Restart=always
RestartSec=5s
StartLimitIntervalSec=300
StartLimitBurst=10
```

**原因**：`on-failure` **不覆盖"退出码为 0 的异常退出"**。本服务就存在这种情形：上游在某些信号处理路径下会以 0 退出（例如收到非预期的信号），此时 `on-failure` 会让服务**静默死掉**，没有任何重启、也没有告警。

配合 `StartLimitIntervalSec=300` + `StartLimitBurst=10`：5 分钟内最多重启 10 次，超过则进入 `failed` 状态**停止重启**。这是必要的防抖 —— 否则一个必然启动失败的配置错误会变成每秒一次的无限重启，把日志刷爆、把 CPU 打满，反而掩盖真正的错误。

**另一个易错点**：`StartLimitIntervalSec` 与 `StartLimitBurst` 属于 **`[Unit]`** 段（systemd ≥ 229 起），**不是 `[Service]`**。放在 `[Service]` 里会被**静默忽略**——不报错、不生效，防抖形同虚设。

**预期效果**：任何退出都被重启；但配置性错误不会导致重启风暴，而是明确停在 `failed` 待排查。

**验证**：
```bash
systemctl show ofm -p Restart -p StartLimitIntervalUSec -p StartLimitBurst
# → always / 5min / 10
# 制造启动失败，观察是否在 10 次后停止
systemctl stop ofm && mv /var/lib/ofm /var/lib/ofm.bak && systemctl start ofm
sleep 60 && systemctl status ofm | head -20     # 应显示 failed 且有 "start request repeated too quickly"
mv /var/lib/ofm.bak /var/lib/ofm && systemctl reset-failed ofm && systemctl start ofm
```

**回滚**：改回 `Restart=on-failure`。会失去对 0 退出码异常退出的覆盖。

### 5.5 `ExecStartPre` 与 `ExecStartPost`

**改动**：
```ini
ExecStartPre=/opt/ofm/scripts/clear-stale-lock.sh /var/lib/ofm
ExecStart=/usr/bin/node cli.mjs --port 18900 --data-dir /var/lib/ofm $OFM_EXTRA_ARGS
ExecStartPost=/opt/ofm/scripts/wait-ready.sh http://127.0.0.1:18900 60
```

**原因**：
- `ExecStartPre` 保证**每次重启都先做清锁判定**，即使崩溃发生在 systemd 之外（OOM Killer、手工 `kill -9`）。
- `ExecStartPost` 让 systemd **等到服务真的就绪**才认为 `start` 成功。否则 `systemctl start` 返回 0 时服务可能还在初始化 —— 后续的依赖服务会拿到"启动了但不可用"的假象。
- `$OFM_EXTRA_ARGS` **有意不加引号**（shellcheck 会告警），需要它展开成多个参数。这是给运维留的挂钩（例如追加 `--no-refresh`）。

**⚠️ 刻意**没有** `ExecReload`**：旧单元里有 `ExecReload=/bin/kill -HUP $MAINPID`，这是个**真实 bug** —— 上游只处理 SIGINT/SIGTERM，**SIGHUP 会直接杀死进程**。`systemctl reload ofm` 本该是"平滑重载"，实际是"静默杀服务"。已删除。

**预期效果**：重启路径自动处理陈旧锁；`systemctl start` 的返回码真实反映可用性；`systemctl reload` 不再是个陷阱。

**验证**：
```bash
systemctl show ofm -p ExecStartPre -p ExecStartPost -p ExecReload
# → ExecReload 应为空
systemctl restart ofm && echo "启动成功（含就绪校验）"
# 造陈旧锁后重启，应自动恢复
echo '{"pid":999999,"product":"our-free-model-standalone"}' > /var/lib/ofm/service.lock
systemctl restart ofm && journalctl -u ofm -n 10 | grep 陈旧
```

**回滚**：删除对应行。删 `ExecStartPost` 会让 `systemctl start` 的语义变弱。

---

## 6. 本机验证记录

本机为 Windows + Git Bash 环境。**Docker 不可用**（`docker: command not found`），因此容器构建与运行时验证留待目标服务器（见 §7）。

### 6.1 nginx 配置语法（真实解析器）

用官方 Windows 构建的 nginx **真实解析**每个配置文件（不只是肉眼审查），并把容器路径重写为本地等价路径：

| 配置 | nginx 1.31.3（最新） | nginx 1.24.0（Ubuntu 24.04 自带） |
|---|---|---|
| `deploy/docker/nginx.conf` | **PASS** | **PASS** |
| `deploy/nginx/ofm.conf` | **PASS** | **PASS** |
| `deploy/nginx/ofm-tls.conf` | **PASS** | **PASS** |

仅有两类**预期内**的告警：1.31.3 上 `listen ... http2` 的弃用提示（正是 §3.7 选择旧写法的原因）；自签名证书导致的 `ssl_stapling ... no OCSP responder URL`（真实证书下不会出现）。

> 验证过程本身修掉了一个 harness bug（相对证书路径被拼接两次），以及**两处真实的配置错误**：`log_format` 误放进 `server {}`、以及在 bridge 网络不存在 IPv6 的情况下监听 `[::]:8080`。

### 6.2 脚本层实测（对真实运行实例）

启动了一个真实实例（`node app/cli.mjs --port 18977 --data-dir <tmp> --no-refresh`）逐项实测：

| 测试 | 结果 |
|---|---|
| `healthcheck.sh --quick` | **PASS**，exit 0（含 liveness、无 Key 必须 401、数据目录可写） |
| `wait-ready.sh` | exit 0，0 秒完成 |
| `preflight.sh` | **PASS**（3 项 WARN：目录权限过宽、内存偏低、存在旧锁 —— 均为正确告警） |
| `clear-stale-lock.sh` | 已死 PID / 无 pid 字段 / 无锁 / `--force` / 缺参数 **5 个分支全部正确**；活跃实例分支见下方说明 |
| `diagnostics.sh` | 完整只读快照，exit 0；**内置泄漏自检判定"未发现高危凭据"**；用脚本内真实正则跑 11 个样本 —— 真凭据 **6/6 命中**、环境变量名/协议头名/正常配置行 **5/5 不误报**；数据目录放一份明文含 Key 的文件，输出中该内容出现 **0 次** |
| POSIX 兼容性 | 所有 `/bin/sh` 脚本 `sh -n` 通过 |

**陈旧锁恢复闭环（完整走通）**：
```
1. taskkill /F 硬杀实例（模拟 docker kill / SIGKILL）
2. 确认端口释放 + service.lock 残留          ✓
3. clear-stale-lock.sh → 识别陈旧、删除锁、exit 0   ✓
4. 清锁后直接启动 → 就绪                    ✓
5. healthcheck.sh --quick → PASS            ✓
6. 端口 18977 正常监听                      ✓
```

**锁判定的反直觉缺陷（活体测试发现）**：`kill -0` 对"属于其他用户的存活进程"返回非零 → 活跃实例被误判为已死 → **删掉了正在运行实例的锁**。修复为「`/proc/<pid>` 存在 **或** `kill -0` 成功」双判据。这个缺陷只在多用户/容器场景下暴露，纯代码审查极难发现。

> ⚠️ **必须如实说明的一项**：「活跃实例保护」这一分支**在本机无法验证**。Windows/MSYS 的 `/proc` 只索引 MSYS 自身 PID，而 `service.lock` 存的是 Node 报出的原生 Windows PID → `/proc/<pid>` 不存在；同一 PID 上 `kill -0` 也报 `No such process`（ESRCH，不是 EPERM）。两个判据同时假阴性，实测结果是**误删了存活实例的锁**。
>
> 这是 MSYS 的环境特性，**不代表 Linux 行为** —— Linux 的 `/proc/<pid>` 对进程存在性是权威的，这正是该设计成立的前提。但既然本机无法验证，就不能在文档里声称验证过。该分支已列入 §7 必测清单（第 8 项），务必在 Linux 上跑通。

### 6.3 V8 堆上限（§2.1 的数据来源）

```
默认        → heap_size_limit = 4144 MiB
--max-old-space-size=1024 → heap_size_limit = 1072 MiB
```

### 6.4 compose 文件结构校验

用 PyYAML 解析 `docker-compose.yml`（隔离 venv 内安装 pyyaml 6.0.3），**8 项一致性断言全部通过**：`read_only`、`restart`、`cap_drop: ALL`、`stop_grace_period(40s) > OFM_STOP_TIMEOUT(25s)`、日志轮转、nginx tmpfs、端口只发布回环、`env_file.required: false`。

### 6.5 `wait -n` 的信号陷阱（实验确认）

`wait -n` 在**收到已 trap 的信号但没有子进程死亡**时返回 `128+signo`（实测 `RC=143`，**子进程经确认仍存活**）。这正是 §4.4 中 `STOPPING` 标志位存在的理由 —— 不加判断，一次正常 `docker stop` 会被误报为"nginx 退出"并以 143 结束。

### 6.6 文档 ↔ 代码一致性校验（126 项断言全通过）

本文档里写了大量"配置 X 已设为 Y"的声明。**文档与实现漂移本身就是生产风险** —— 照着错的文档做回滚、按错的值调参，代价比没有文档更高。因此本轮做了一次机械校验：把文档里的关键声明逐条转成对实际文件的断言。

**校验方法**（两个关键处理，否则全是误报）：
1. **折叠连续空白**：nginx / systemd 配置惯用多空格对齐（`worker_processes    2;`、`proxy_buffering    off;`），单空格正则匹配不到。
2. **去注释行**：很多"不该出现"的模式只出现在**解释性注释**里（例如 `docker/nginx.conf` 的注释解释"刻意不写 `worker_rlimit_nofile`"）。用带注释的原文做反向断言会全部误报。

**结果**：`126 项通过 / 0 项失败`。脚本已收进仓库，可随时复跑：

```bash
bash tools/verify-docs.sh          # 通过则 exit 0
```

**校验过程中发现并修掉的 2 处真实偏差**（其余 16 处是校验脚本自身的误报）：

| 偏差 | 文档原本写的 | 实际 | 处置 |
|---|---|---|---|
| §2.3 把 `keepalive` 与 `keepalive_timeout` 混为一个参数，并声称裸机是 60 | `keepalive 32（容器）/ 60（裸机）` | 三份配置**统一都是 `keepalive 32;`**，裸机另有 `keepalive_timeout 60s;` | **修正文档** |
| §4.5 声称 `diagnostics.sh` 内置泄漏自检 | "末尾用 `grep -E '...'` 做泄漏自检" | 脚本里**只有一句人工提示**，没有自动检查 | **修正代码**（真正实现自检并加退出码） |

第 2 条尤其值得记下：**文档承诺了一个并不存在的安全机制**。如果没做这次校验，运维会以为"跑完 diagnostics 就能安心外发"，而实际上完全依赖人的自觉。发现后选择补代码而不是删文档 —— 因为它本来就是该有的东西。

另外还借这次校验修正了 §5.2 一处**无法复现的验证记录**（活跃实例保护在 MSYS 上测不出来，详见 §6.2 的说明）。

---

## 7. 目标服务器验证清单

以下项目**无法在本机验证**（本机无 Docker、非 Linux systemd），**上线前必须在目标服务器逐项跑通**。这不是可选项——每一条都对应一个已知的真实故障模式。

### 7.1 Docker 路径

```bash
# [ ] 1. 构建成功（含 Node 基线校验）
docker compose -f deploy/docker-compose.yml build

# [ ] 2. 无凭据进镜像（§1.5）
docker run --rm our-free-model-server:latest sh -c 'ls /opt/ofm/env 2>/dev/null && echo LEAK || echo OK'
#     期望 OK

# [ ] 3. npm 已移除（§1.2）
docker run --rm our-free-model-server:latest sh -c 'command -v npm || echo no-npm'

# [ ] 4. 启动并达到 healthy
docker compose -f deploy/docker-compose.yml up -d && sleep 70
docker inspect ofm --format '{{.State.Health.Status}}'      # 期望 healthy

# [ ] 5. 非 root + 零 capability（§3.1）
docker exec ofm id                                          # uid=10001
docker exec ofm grep CapEff /proc/self/status               # 0000000000000000

# [ ] 6. 只读根文件系统真实生效（§3.4）
docker exec ofm sh -c 'touch /opt/ofm/x' 2>&1 | grep -qi "read-only" && echo OK
#     ⚠️ 重点观察：启动日志里**不应**出现 EROFS / EACCES。
#        若出现，定位是哪条写路径，优先补 DSH_HOME 或 tmpfs，而非关闭 read_only。

# [ ] 7. 优雅停止不残留锁（§5.3）
docker stop ofm
docker run --rm -v ofm_ofm-data:/d alpine ls /d/service.lock 2>&1 | grep -q "No such" && echo "OK 锁已清理"
#     （卷名以 `docker volume ls` 实际为准）

# [ ] 8. 硬杀 + 自动恢复闭环（§5.2）
docker kill ofm          # 不给清理机会
docker start ofm && sleep 20
docker logs ofm 2>&1 | grep -E "陈旧|未能找到"      # 应出现自动清锁记录
docker inspect ofm --format '{{.State.Health.Status}}'   # 回到 healthy

# [ ] 9. 【必测】活跃实例保护（§5.2）—— 本机 MSYS 无法验证，只能在这里验
#     目的：确认不会误删一个正在运行实例的锁（否则会出现并发双实例）
docker compose -f deploy/docker-compose.yml up -d
PANIC_DATA=/tmp/oft-probe
rm -rf $PANIC_DATA && mkdir -p $PANIC_DATA
# 用同一份 app 起第二个实例（换端口，避免端口冲突）
docker exec ofm sh -c 'cp -r /opt/ofm/app /tmp/a2 && cd /tmp/a2 && OFM_HOME=/data2 node cli.mjs --port 18990 --data-dir /tmp/a2data --no-refresh &' 
sleep 15
# 直接对真实锁文件跑判定：此时该实例确实活着，必须 exit 1 且锁保留
docker exec ofm bash /opt/ofm/scripts/clear-stale-lock.sh /data2; echo "rc=$?（期望 1）"
docker exec ofm ls -l /data2/service.lock && echo "锁保留 ✓"
#     ⚠️ 若 rc=0 且锁被删 → /proc 判定失效，必须先修好再上线（会并发双实例）

# [ ] 10. 崩溃触发重启（§5.1）—— 最关键的验证
docker exec ofm pkill -f cli.mjs
sleep 30 && docker inspect ofm --format '{{.State.Status}} {{.RestartCount}}'
#     期望：running，且 RestartCount 已 +1（证明 restart 策略真的生效，
#     而不是像旧版那样"容器不退、服务永久 502"）

# [ ] 11. 日志轮转上限（§4.1）
docker inspect ofm --format '{{json .HostConfig.LogConfig}}'    # max-size 20m / max-file 5

# [ ] 12. 管理台可用（§3.3）—— 403 是这里的头号坑
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/management/overview
#     期望 401（需登录）；若为 403 → Host/Origin 重写有问题

# [ ] 13. 流式不被缓冲（§2.3）
curl -N -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H 'Content-Type: application/json' \
  -d '{"model":"kilo-auto/free","messages":[{"role":"user","content":"从1数到30"}],"stream":true}'
#     期望逐块输出

# [ ] 14. OOM 行为符合预期（§2.1）
docker stats ofm --no-stream        # 内存占用应稳定低于 2g
#     ⚠️ 若出现 exit 137 且日志空白 → NODE_OPTIONS 未生效，检查 environment 是否被 env 文件覆盖
```

### 7.2 裸机 / systemd 路径

> **第 9 项（活跃实例保护）在裸机形态下同样必测，且命令更简单** —— 服务正跑着的时候直接跑一遍判定即可：
> ```bash
> sudo /opt/ofm/scripts/clear-stale-lock.sh /var/lib/ofm; echo "rc=$?"
> #     期望 rc=1 + "检测到活跃服务实例"，且 /var/lib/ofm/service.lock 保留
> #     若 rc=0 且锁被删 → /proc 判定在该内核/挂载参数下失效（见 §5.2 已知局限），
> #     必须先修好再上线：会并发双实例
> mount | grep ' /proc '        # 顺带确认没有 hidepid=1/2
> ```

```bash
# [ ] 14. 安装脚本可重复执行（幂等）
sudo bash deploy/scripts/install-bare.sh && sudo bash deploy/scripts/install-bare.sh
#     第二次不应报错

# [ ] 15. systemd 单元语法（需 systemd ≥ 229）
systemd-analyze verify /etc/systemd/system/ofm.service

# [ ] 16. 加固指令生效（§3.8）
systemd-analyze security ofm.service          # 应给出较低的 exposure 评分
systemctl show ofm -p Restart -p LimitNOFILE -p MemoryDenyWriteExecute -p ProtectSystem
#     期望 always / 65536 / no / strict
#     ⚠️ MemoryDenyWriteExecute 必须是 no —— 若为 yes，Node 的 JIT 与 Qoder WASM 会直接起不来

# [ ] 17. 重启防抖（§5.4）
#     制造必然启动失败后观察是否在 10 次内停止，而非无限重启
sudo mv /var/lib/ofm /var/lib/ofm.bak && sudo systemctl start ofm
sleep 70 && systemctl status ofm | grep -i "repeated too quickly"
sudo mv /var/lib/ofm.bak /var/lib/ofm && sudo systemctl reset-failed ofm && sudo systemctl start ofm

# [ ] 18. ExecReload 确认为空（避免 SIGHUP 杀服务）
systemctl show ofm -p ExecReload        # 应为空

# [ ] 19. journald drop-in 生效（§4.1）
sudo cp deploy/systemd/journald-ofm.conf /etc/systemd/journald.conf.d/ofm.conf
sudo systemctl restart systemd-journald
systemctl show systemd-journald -p SystemMaxUse -p RateLimitBurst

# [ ] 20. 健康检查 timer
systemctl list-timers ofm-healthcheck.timer
sudo systemctl start ofm-healthcheck.service && journalctl -u ofm-healthcheck -n 20

# [ ] 21. UMask 生效（凭据文件权限，§3.8）
stat -c '%a %U:%G' /var/lib/ofm/settings.json      # 期望 600 ofm:ofm

# [ ] 22. nginx 版本对 http2 写法的兼容（§3.7）
nginx -v            # >= 1.25.1 可改用 `http2 on;`；1.24 必须用当前的 listen ssl http2
sudo nginx -t
```

### 7.3 网络与安全

```bash
# [ ] 23. 端口未对外暴露（§3.5）
ss -tlnp | grep -E '18900|8080'      # 应为 127.0.0.1，不是 0.0.0.0
#     从外部机器 curl http://<公网IP>:8080/health → 连接被拒

# [ ] 24. 限流生效（§3.2）
for i in $(seq 1 80); do curl -s -o /dev/null -w '%{http_code}\n' https://你的域名/health; done | sort | uniq -c
#     期望出现 429

# [ ] 25. 若有前置代理：真实 IP 透传配置正确（§3.2 注意事项）
#     ⚠️ 用两个不同外网 IP 各打 50 次请求，若都很快 429 → $remote_addr 是代理 IP，
#        需配置 set_real_ip_from / real_ip_header，否则正常用户会被误伤

# [ ] 26. TLS 与安全头（§3.6 / §3.7）
sudo nginx -t && sudo systemctl reload nginx
curl -sI https://你的域名/health | grep -iE 'strict-transport|x-content-type|x-frame|referrer|^server'
openssl s_client -connect 你的域名:443 -tls1_1 </dev/null 2>&1 | grep -i alert
#     建议在线复核：ssllabs.com 与 securityheaders.com

# [ ] 27. 管理台实际打开（浏览器）
docker logs ofm 2>&1 | grep 管理页面     # 或 journalctl -u ofm
#     用一次性链接打开，界面应完整渲染（不是 403、不是不停转圈）
```

---

## 8. 上线与回滚手册

### 8.1 首次上线（Docker）

```bash
cd ofm-server

# 1) 全量生产编排（推荐：一条命令拿到加固后的部署）
docker compose -f deploy/docker-compose.yml up -d --build

# 2) 首次上线建议先跳过启动刷新，避免启动即打上游、拖慢就绪
#    在 deploy/env/ofm.env 里写：OFM_EXTRA_ARGS=--no-refresh
#    （文件不存在时 compose 不会报错）

# 3) 确认健康
docker inspect ofm --format '{{.State.Health.Status}}'

# 4) 拿一次性管理链接，登录并配置渠道
docker logs ofm 2>&1 | grep 管理页面

# 5) 对外暴露（任选其一）
#    a) 前置你自己的 TLS 终止，反代到 127.0.0.1:8080
#    b) 裸机 + deploy/nginx/ofm-tls.conf（certbot 申请证书）
#    c) 临时：把 ports 改成 "443:8080" —— 不推荐，容器内无 TLS
```

### 8.2 首次上线（裸机）

```bash
cd ofm-server
sudo bash deploy/scripts/install-bare.sh          # 建用户/装到 /opt/ofm/注册 systemd/启动
sudo cp deploy/nginx/ofm-tls.conf /etc/nginx/conf.d/ofm.conf
sudo vi /etc/nginx/conf.d/ofm.conf                # 改 server_name 与证书路径
sudo nginx -t && sudo systemctl reload nginx
sudo bash deploy/scripts/healthcheck.sh https://你的域名 /var/lib/ofm
```

### 8.3 回滚

**代码层**：本轮所有改动都在 `deploy/` 目录，`app/` 未动（`app/` 由 `tools/build-app.mjs` 生成，请勿手改）。回滚粒度很小。

```bash
git diff --stat HEAD -- deploy/          # 先看改了哪些
git checkout HEAD -- deploy/docker-compose.yml deploy/Dockerfile   # 按需选择性回滚
```

**部署方式整体退回（最保守）**：直接用上游的"最小可用"启动方式，放弃本轮全部加固：

```bash
# Docker：不加载加固编排
docker run -d --name ofm -p 127.0.0.1:8080:8080 \
  -v ofm-data:/data -e OFM_HOME=/data \
  our-free-model-server:latest

# 裸机：直接前台跑（绕过 systemd 沙箱与清锁）
sudo -u ofm OFM_HOME=/var/lib/ofm node /opt/ofm/app/cli.mjs --port 18900 --data-dir /var/lib/ofm
```

**各项独立回滚开关**（不必整体退回，按症状定位）：

| 症状 | 最可能的改动项 | 临时开关 |
|---|---|---|
| 启动时报 `EROFS` / `EACCES` | §3.4 只读根文件系统 | `read_only: false`，或补 `DSH_HOME` / tmpfs |
| Node 启动即退出、日志见 `SIGSYS`/`mmap` | §3.8 `MemoryDenyWriteExecute` | 确认它是 `false` |
| 管理接口 403 | §3.3 Host/Origin 重写 | 检查 `${OFM_PORT}` 是否已被替换（`grep -c '\${'`） |
| 正常客户端被大量 429 | §3.2 限流 / 真实 IP | 放宽 `rate`，或配 `set_real_ip_from` |
| 服务"启动了"但立刻不可用 | §5.5 `ExecStartPost` | 临时删除该行 |
| 停止后仍残留锁 | §5.3 停机链路 | 确认 `stop_grace_period > OFM_STOP_TIMEOUT`；`docker inspect` 看 exit code 是否为 137/143 |
| nginx 报 `unknown directive "http2"` | §3.7 | 换回 `listen 443 ssl http2;`（或用 §7.2 第 22 项确认版本） |
| 部署后磁盘被日志写满 | §4.1 | 检查 `logging.options` 是否被其他 compose 覆盖文件吃掉 |

### 8.4 备份（含明文凭据，务必加密）

```bash
# 停止服务保证一致性（或用文件系统快照）
docker stop ofm
tar czf ofm-data-$(date +%F).tar.gz -C /var/lib/ofm .
gpg -c ofm-data-$(date +%F).tar.gz        # ← 必须加密：内部含明文渠道凭据与 API Key
docker start ofm
```

### 8.5 运维日常

| 频率 | 动作 |
|---|---|
| 每日 | `docker compose ps` 看健康状态；`docker stats` 扫一眼内存 |
| 每周 | `journalctl -u ofm --since "7 days ago" \| grep -iE "error\|crash"`；检查磁盘 `df -h` |
| 每月 | 轮换 API Key（管理台「API 接入」）；复核下游客户端是否已更新 |
| 每季 | 复核上游 `dsh-our-free-model` 更新 → `tools/build-app.mjs` 重新生成 → 按 §7 清单重验；复核 `docs/COMPLIANCE.md` |

**事故第一动作**：
```bash
bash deploy/scripts/diagnostics.sh /var/lib/ofm bare | tee /tmp/diag-$(date +%s).txt
# 该输出经脱敏自检，可安全外发
grep -nE 'forwardKey|sk-|token|=eyJ' /tmp/diag-*.txt   # 二次确认无凭据（必须无输出）
```

---

## 附：完整文件树（本轮新增 / 修改以 ← 标注）

```
ofm-server/
├── deploy/
│   ├── Dockerfile                      ← 修改：非 root(10001)、去 npm、OCI 标签、HEALTHCHECK、tini
│   ├── docker-compose.yml              ← 修改：资源限额、cap_drop、read_only、日志轮转、健康检查
│   ├── .dockerignore                   ← 修改：排除凭据文件（关键）
│   ├── docker/
│   │   ├── entrypoint.sh               ← 修改：监督模式、信号转发、端口漂移检测、双配置替换
│   │   ├── nginx.conf                  ← 修改：限流、SSE 免缓冲、日志治理、非 root 临时目录
│   │   └── ofm-proxy-headers.conf      ← 新增：共享请求头（Host/Origin 重写）
│   ├── nginx/
│   │   ├── ofm.conf                    ← 修改：限流、log_format 位置、安全头、三 location
│   │   └── ofm-tls.conf                ← 修改：TLS 加固、OCSP 装订、HSTS（不含 preload）
│   ├── systemd/
│   │   ├── ofm.service                 ← 修改：Restart=always、沙箱、删 ExecReload、清锁/就绪钩子
│   │   ├── ofm-healthcheck.service     ← 新增
│   │   ├── ofm-healthcheck.timer       ← 新增
│   │   ├── journald-ofm.conf           ← 新增
│   │   └── ofm.logrotate               ← 新增（可选）
│   ├── scripts/
│   │   ├── clear-stale-lock.sh         ← 新增：陈旧锁判定（/proc 权威判断）
│   │   ├── wait-ready.sh               ← 新增
│   │   ├── preflight.sh                ← 新增
│   │   ├── diagnostics.sh              ← 新增（内置脱敏自检）
│   │   ├── healthcheck.sh              ← 修改：去 python3 依赖，改用 node 解析 JSON
│   │   └── install-bare.sh             ← 修改：幂等、Node 版本校验、装 healthcheck timer
│   └── env/ofm.env.example             ← 修改：全量变量（经代码核对）
└── docs/
    ├── ARCHITECTURE.md                 # 逆向分析报告
    ├── COMPLIANCE.md                   # 合规与隐私
    └── PRODUCTION.md                   ← 本文档
```

```
ofm-server/tools/
├── build-app.mjs        # 从上游重新生成 app/（升级用）
└── verify-docs.sh       ← 新增：断言本文档的声明与实际配置一致（126 项，可复跑）
```
