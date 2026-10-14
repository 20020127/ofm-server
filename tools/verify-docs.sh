#!/usr/bin/env bash

# 用法：bash tools/verify-docs.sh        （在仓库任意位置执行均可）
#   断言 docs/PRODUCTION.md 里声明的关键配置确实存在于实际文件中。
#   通过时输出「结果：文档声明与实际代码/配置一致」并 exit 0。
#
# 维护提示（这两个坑会让整个脚本全是误报）：
#   1) nginx/systemd 配置惯用多空格对齐 —— 断言前必须折叠连续空白；
#   2) 很多「不该出现」的模式只出现在解释性注释里 —— 反向断言必须先去注释行。
#   需要检查注释本身时用 rawchk/flatchk。
# 一次性校验：docs/PRODUCTION.md 的声明是否与实际代码/配置一致
#
# 做法：把每个文件规范化后（折叠连续空白 + 去注释行）再匹配，
# 避免被 nginx/systemd 常见的「多空格对齐」和「解释性注释」误判。
cd "$(dirname "$0")/.." || exit 1   # 脚本位于 <repo>/tools/，切到仓库根
pass=0; fail=0
NORM="/tmp/vdocs-norm"
mkdir -p "$NORM"

nrm() { # nrm <file>  -> 打印规范化结果（折叠空白、去整行注释）
  [ -f "$1" ] || { echo ""; return; }
  sed 's/[[:space:]]\+/ /g' "$1" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}
docnrm() { # 文档专用：只折叠空白。markdown 的 # 是标题而非注释，不能用 nrm
  [ -f "$1" ] || { echo ""; return; }
  sed 's/[[:space:]]\+/ /g' "$1"
}
nrmraw() { # 保留注释（用于"刻意不写 X"这类注释性断言）
  [ -f "$1" ] || { echo ""; return; }
  sed 's/[[:space:]]\+/ /g' "$1"
}

chk()  { if nrm "$2"      | grep -qE "$3"; then echo "  OK   $1"; pass=$((pass+1)); else echo "  FAIL $1  [期望 $2 有 /$3/]"; fail=$((fail+1)); fi; }
nchk() { if nrm "$2"      | grep -qE "$3"; then echo "  FAIL $1  [不应有 /$3/]"; fail=$((fail+1)); else echo "  OK   $1"; pass=$((pass+1)); fi; }
rawchk(){ if nrmraw "$2"  | grep -qE "$3"; then echo "  OK   $1"; pass=$((pass+1)); else echo "  FAIL $1  [期望 $2 含注释 /$3/]"; fail=$((fail+1)); fi; }
flatchk(){ # 把续行（\ 换行）合并后再匹配，用于跨行指令（如 Dockerfile 的 HEALTHCHECK）
  if nrmraw "$2" | sed ':a; /\\$/ { N; s/\\\n//; ba }' | grep -qE "$3"; then
    echo "  OK   $1"; pass=$((pass+1))
  else
    echo "  FAIL $1  [期望 $2 有跨行 /$3/]"; fail=$((fail+1))
  fi
}
docchk(){ if docnrm "$2"  | grep -qE "$3"; then echo "  OK   $1"; pass=$((pass+1)); else echo "  FAIL $1  [期望 $2 有 /$3/]"; fail=$((fail+1)); fi; }
cntchk(){ # cntchk <描述> <文件> <模式> <期望行数> —— sed 逐行处理，跨行计数须逐行数
  local n; n=$(nrm "$2" | grep -cE "$3")
  if [ "$n" = "$4" ]; then echo "  OK   $1"; pass=$((pass+1)); else echo "  FAIL $1  [期望 $2 有 $4 行 /$3/，实际 $n 行]"; fail=$((fail+1)); fi
}

echo "[1] 环境与依赖"
chk "Dockerfile 可参数化基础镜像"       deploy/Dockerfile            'ARG NODE_IMAGE=node:22\.19\.0-alpine'
chk "Dockerfile 移除 npm"               deploy/Dockerfile            'rm -rf /usr/local/lib/node_modules/npm'
chk "Dockerfile OCI version 标签"       deploy/Dockerfile            'org\.opencontainers\.image\.version'
chk "Dockerfile OCI revision 标签"      deploy/Dockerfile            'org\.opencontainers\.image\.revision'
chk "Dockerfile 非 root uid 10001"      deploy/Dockerfile            'adduser -u 10001'
flatchk "Dockerfile HEALTHCHECK 走 nginx 端口" deploy/Dockerfile      'HEALTHCHECK.*OFM_PROXY_PORT\}/health'
chk "Dockerfile tini 作 PID1"           deploy/Dockerfile            'ENTRYPOINT \["/sbin/tini"'
chk ".dockerignore 排除凭据文件"        deploy/.dockerignore         '^deploy/env/ofm\.env$'
chk ".dockerignore 保留 .env.example"   deploy/.dockerignore         '^!\.env\.example$'
chk "compose env_file 可选"             deploy/docker-compose.yml    'required: false'

echo "[2] 性能与资源"
chk "compose 内存限额 2g"               deploy/docker-compose.yml    'memory: 2g'
chk "compose CPU 限额 2.0"              deploy/docker-compose.yml    'cpus: "2\.0"'
chk "compose pids_limit 512"            deploy/docker-compose.yml    'pids_limit: 512'
chk "compose nofile 65536"              deploy/docker-compose.yml    'soft: 65536'
chk "compose core ulimit 已声明"        deploy/docker-compose.yml    'core:'
chk "NODE_OPTIONS 堆上限 1024"          deploy/docker-compose.yml    'max-old-space-size=1024'
chk "容器 nginx worker_processes 2"     deploy/docker/nginx.conf     'worker_processes 2;'
nchk "容器 nginx 无 worker_rlimit_nofile" deploy/docker/nginx.conf   'worker_rlimit_nofile'
chk "容器 nginx upstream keepalive 32"  deploy/docker/nginx.conf     'keepalive 32;'
chk "裸机 nginx upstream keepalive 32"  deploy/nginx/ofm.conf        'keepalive 32;'
chk "SSE location 关缓冲"               deploy/docker/nginx.conf     'proxy_buffering off;'
chk "流式读超时 3600s"                  deploy/docker/nginx.conf     'proxy_read_timeout 3600s;'
chk "chunked 传输开启"                  deploy/docker/nginx.conf     'chunked_transfer_encoding on;'
chk "client_max_body_size 32m"          deploy/docker/nginx.conf     'client_max_body_size 32m;'

echo "[3] 安全与访问"
chk "compose no-new-privileges"         deploy/docker-compose.yml    'no-new-privileges:true'
chk "compose cap_drop ALL"              deploy/docker-compose.yml    'cap_drop:'
chk "compose read_only true"            deploy/docker-compose.yml    'read_only: true'
chk "tmpfs /tmp 16m"                     deploy/docker-compose.yml    '/tmp:size=16m'
chk "tmpfs /run 4m"                      deploy/docker-compose.yml    '/run:size=4m'
chk "tmpfs /var/lib/nginx/tmp 64m"       deploy/docker-compose.yml    'nginx/tmp:size=64m'
chk "端口只发布到回环"                  deploy/docker-compose.yml    '127\.0\.0\.1:8080:8080'
chk "共享头 Host 回环+端口"             deploy/docker/ofm-proxy-headers.conf 'proxy_set_header Host 127\.0\.0\.1:\$\{OFM_PORT\}'
chk "共享头 Origin 置空"                deploy/docker/ofm-proxy-headers.conf 'proxy_set_header Origin ""'
chk "共享头 Referer 置空"               deploy/docker/ofm-proxy-headers.conf 'proxy_set_header Referer ""'
chk "共享头 http_version 1.1"           deploy/docker/ofm-proxy-headers.conf 'proxy_http_version 1.1'
chk "API 限流 20r/s"                    deploy/docker/nginx.conf     'ofm_api:10m rate=20r/s'
chk "管理限流 10r/s"                    deploy/docker/nginx.conf     'ofm_admin:10m rate=10r/s'
chk "裸机 HTTP 限流"                    deploy/nginx/ofm.conf        'ofm_api:10m rate=20r/s'
chk "裸机 TLS 限流"                     deploy/nginx/ofm-tls.conf    'ofm_api:10m rate=20r/s'
chk "X-Frame-Options DENY"              deploy/nginx/ofm.conf        'X-Frame-Options DENY'
chk "nosniff"                           deploy/nginx/ofm.conf        'X-Content-Type-Options nosniff'
chk "Referrer-Policy no-referrer"       deploy/nginx/ofm.conf        'Referrer-Policy no-referrer'
chk "server_tokens off"                 deploy/nginx/ofm.conf        'server_tokens off'
chk "TLS 用兼容写法 listen ssl http2"   deploy/nginx/ofm-tls.conf    'listen 443 ssl http2;'
nchk "TLS 不用 http2 on;"               deploy/nginx/ofm-tls.conf    '^http2 on;'
chk "TLS 协议限 1.2/1.3"                deploy/nginx/ofm-tls.conf    'ssl_protocols TLSv1\.2 TLSv1\.3;'
chk "TLS 会话票据关闭"                  deploy/nginx/ofm-tls.conf    'ssl_session_tickets off;'
chk "OCSP 装订"                         deploy/nginx/ofm-tls.conf    'ssl_stapling on;'
chk "OCSP 校验"                         deploy/nginx/ofm-tls.conf    'ssl_stapling_verify on;'
chk "HSTS 已设置（不含子域/预加载）"    deploy/nginx/ofm-tls.conf    'Strict-Transport-Security "max-age=31536000" always;'
nchk "HSTS 实际指令未含 includeSubDomains" deploy/nginx/ofm-tls.conf 'add_header Strict-Transport-Security "[^"]*includeSubDomains'
rawchk "HSTS 的取舍写在注释里"          deploy/nginx/ofm-tls.conf    'includeSubDomains / preload'
chk "systemd ProtectSystem=strict"      deploy/systemd/ofm.service   'ProtectSystem=strict'
chk "systemd NoNewPrivileges"           deploy/systemd/ofm.service   'NoNewPrivileges'
chk "systemd ReadWritePaths"            deploy/systemd/ofm.service   'ReadWritePaths='
chk "systemd UMask=0077"                deploy/systemd/ofm.service   'UMask=0077'
chk "systemd 能力集为空"                deploy/systemd/ofm.service   'CapabilityBoundingSet=$'
chk "systemd RestrictAddressFamilies"   deploy/systemd/ofm.service   'RestrictAddressFamilies='
chk "systemd MemoryDenyWriteExecute=false" deploy/systemd/ofm.service 'MemoryDenyWriteExecute=false'
chk "systemd LimitNOFILE=65536"         deploy/systemd/ofm.service   'LimitNOFILE=65536'
chk "systemd LimitCORE=0"               deploy/systemd/ofm.service   'LimitCORE=0'
chk "install-bare 建系统用户"           deploy/scripts/install-bare.sh 'useradd .*--system'
rawchk "systemd 注释说明拒用 ProtectProc" deploy/systemd/ofm.service 'ProtectProc'

echo "[4] 日志与错误"
chk "compose 日志轮转 max-size"         deploy/docker-compose.yml    'max-size: "20m"'
chk "compose 日志轮转 max-file"         deploy/docker-compose.yml    'max-file: "5"'
chk "容器 nginx error_log 到 stderr"    deploy/docker/nginx.conf     'error_log /dev/stderr'
chk "容器 nginx access_log 到 stdout"   deploy/docker/nginx.conf     'access_log /dev/stdout'
chk "健康探测不入访问日志"              deploy/docker/nginx.conf     'if=\$ofm_loggable'
chk "log_format 已定义（HTTP）"         deploy/nginx/ofm.conf        'log_format ofm'
chk "log_format 已定义（TLS）"          deploy/nginx/ofm-tls.conf    'log_format ofm'
chk "journald 容量上限"                 deploy/systemd/journald-ofm.conf 'SystemMaxUse=500M'
chk "journald 保留系统空间"             deploy/systemd/journald-ofm.conf 'SystemKeepFree=1G'
chk "journald 单文件上限"               deploy/systemd/journald-ofm.conf 'SystemMaxFileSize=50M'
chk "journald 保留期"                   deploy/systemd/journald-ofm.conf 'MaxRetentionSec=2week'
chk "journald 提升速率上限"             deploy/systemd/journald-ofm.conf 'RateLimitBurst=20000'
chk "logrotate 用 copytruncate"         deploy/systemd/ofm.logrotate 'copytruncate'
chk "logrotate 目标仅 /var/log/ofm"     deploy/systemd/ofm.logrotate '/var/log/ofm/'
chk "logrotate maxsize 100M"            deploy/systemd/ofm.logrotate 'maxsize 100M'
chk "entrypoint 用 set -uo pipefail"    deploy/docker/entrypoint.sh  'set -uo pipefail'
chk "healthcheck 改用 node 解析"        deploy/scripts/healthcheck.sh 'node -e'
nchk "healthcheck 无 python3 调用"      deploy/scripts/healthcheck.sh 'python3'
chk "healthcheck 支持 --quick"          deploy/scripts/healthcheck.sh 'quick'
chk "diagnostics 内置泄漏自检 PAT_HIGH" deploy/scripts/diagnostics.sh 'PAT_HIGH='
chk "diagnostics 自检含本服务 Key 前缀" deploy/scripts/diagnostics.sh 'ofm-\[A-Za-z0-9_-\]\{20,\}'
chk "diagnostics 出错返非零"            deploy/scripts/diagnostics.sh 'exit 1'
chk "diagnostics 用 node 判定环境"      deploy/scripts/diagnostics.sh 'NODE_OPTIONS'

echo "[5] 守护与重启"
chk "entrypoint 监督循环 wait -n"       deploy/docker/entrypoint.sh  'wait -n'
chk "entrypoint 转发 SIGTERM 给服务"    deploy/docker/entrypoint.sh  'kill -TERM'
chk "entrypoint STOPPING 标志位"        deploy/docker/entrypoint.sh  'STOPPING'
chk "entrypoint 兜底强杀 SIGKILL"       deploy/docker/entrypoint.sh  'kill -KILL'
chk "entrypoint 端口漂移检测"           deploy/docker/entrypoint.sh  'standalonePort'
chk "entrypoint DSH_HOME 跟随数据目录"  deploy/docker/entrypoint.sh  'DSH_HOME'
chk "entrypoint 替换共享头占位符"       deploy/docker/entrypoint.sh  'ofm-proxy-headers\.conf'
chk "entrypoint 替换主配置占位符"       deploy/docker/entrypoint.sh  'nginx\.generated\.conf'
rawchk "entrypoint 注明退出码契约"      deploy/docker/entrypoint.sh  '退出码'
chk "compose restart unless-stopped"    deploy/docker-compose.yml    'restart: unless-stopped'
chk "compose stop_signal SIGTERM"       deploy/docker-compose.yml    'stop_signal: SIGTERM'
chk "compose stop_grace_period 40s"     deploy/docker-compose.yml    'stop_grace_period: 40s'
rawchk "compose 注释说明不用 init: true" deploy/docker-compose.yml   'init: true'
chk "compose healthcheck 打 nginx 端口" deploy/docker-compose.yml    '127\.0\.0\.1:8080/health'
chk "compose start_period 60s"          deploy/docker-compose.yml    'start_period: 60s'
chk "compose retries 3"                 deploy/docker-compose.yml    'retries: 3'
chk "systemd Restart=always"            deploy/systemd/ofm.service   'Restart=always'
chk "systemd RestartSec=5s"             deploy/systemd/ofm.service   'RestartSec=5s'
chk "systemd StartLimitBurst=10"        deploy/systemd/ofm.service   'StartLimitBurst=10'
chk "systemd StartLimitIntervalSec=300" deploy/systemd/ofm.service   'StartLimitIntervalSec=300'
nchk "systemd 已删除 ExecReload"        deploy/systemd/ofm.service   '^ExecReload='
chk "systemd ExecStartPre 清锁"         deploy/systemd/ofm.service   'ExecStartPre=.*clear-stale-lock'
chk "systemd ExecStartPost 就绪等待"    deploy/systemd/ofm.service   'ExecStartPost=.*wait-ready'
chk "systemd KillMode=mixed"            deploy/systemd/ofm.service   'KillMode=mixed'
chk "systemd TimeoutStopSec=30s"        deploy/systemd/ofm.service   'TimeoutStopSec=30s'
chk "systemd MemoryMax=2G"              deploy/systemd/ofm.service   'MemoryMax=2G'
chk "systemd MemoryHigh=1536M"          deploy/systemd/ofm.service   'MemoryHigh=1536M'
chk "systemd CPUQuota=200%"             deploy/systemd/ofm.service   'CPUQuota=200%'
chk "systemd TasksMax=512"              deploy/systemd/ofm.service   'TasksMax=512'
chk "systemd DSH_HOME 已注入"           deploy/systemd/ofm.service   'DSH_HOME='
chk "systemd EnvironmentFile 可选"      deploy/systemd/ofm.service   'EnvironmentFile=-'
chk "清锁脚本 /proc 权威判据"           deploy/scripts/clear-stale-lock.sh '\[ -d "/proc/\$PID" \]'
chk "清锁脚本 kill -0 取或兜底"         deploy/scripts/clear-stale-lock.sh 'elif kill -0 "\$PID"'
rawchk "清锁脚本注明 hidepid 局限"       deploy/scripts/clear-stale-lock.sh 'hidepid'
chk "healthcheck timer 随机抖动"        deploy/systemd/ofm-healthcheck.timer 'RandomizedDelaySec'
chk "healthcheck timer 周期 5min"       deploy/systemd/ofm-healthcheck.timer 'OnUnitActiveSec=5min'
chk "healthcheck service 用 Requisite"  deploy/systemd/ofm-healthcheck.service 'Requisite=ofm.service'
chk "healthcheck service --quick"       deploy/systemd/ofm-healthcheck.service 'quick'
chk "wait-ready 有超时兜底"             deploy/scripts/wait-ready.sh  'journalctl'
chk "preflight 检查数据目录权限"        deploy/scripts/preflight.sh   '权限'

echo "[6] 对外基地址（反向代理感知）"
docchk "PRODUCTION.md 有 §3.3.1 小节"   docs/PRODUCTION.md           '^### 3\.3\.1 对外基地址'
docchk "PRODUCTION.md 说明推导优先级"   docs/PRODUCTION.md           'OFM_PUBLIC_BASE_URL'
docchk "PRODUCTION.md 记录实测根因"     docs/PRODUCTION.md           '硬编码'
docchk "PRODUCTION.md 写明回滚方法"     docs/PRODUCTION.md           '退回「显示回环地址」'
docchk "ARCHITECTURE.md 有 §2.3 小节"   docs/ARCHITECTURE.md         '^### 2\.3 对外基地址'
docchk "ARCHITECTURE.md 说明可信判据"   docs/ARCHITECTURE.md         'Host.{0,14}已是回环名'
docchk "ARCHITECTURE.md 源码索引含补丁" docs/ARCHITECTURE.md         'src/public-url\.js'
chk "补丁模块存在"                       tools/patches/public-url.js  'export function publicBaseUrl'
chk "补丁模块有回环可信判据"             tools/patches/public-url.js  'function fromTrustedProxy'
chk "补丁模块有 authority 形态校验"      tools/patches/public-url.js  'function isPlainAuthority'
chk "build 脚本声明 SERVER_PATCHES"     tools/build-app.mjs          'SERVER_PATCHES'
chk "build 脚本拷入补丁模块"             tools/build-app.mjs          "patches', 'public-url\.js'"
chk "app/service.mjs 引入补丁"           app/service.mjs              "import \{ publicBaseUrl \} from './src/public-url\.js'"
chk "app/service.mjs 用补丁推 baseUrl"   app/service.mjs              'baseUrl: publicBaseUrl\(req,'
chk "app/management.mjs summary 透传"    app/management.mjs           'summary\(req\)'
chk "app/management.mjs info 透传"       app/management.mjs           'info\(req\)'
chk "HTTP vhost 透传 X-Forwarded-Host"   deploy/nginx/ofm.conf        'proxy_set_header X-Forwarded-Host \$host;'
chk "TLS vhost 透传 X-Forwarded-Host"    deploy/nginx/ofm-tls.conf    'proxy_set_header X-Forwarded-Host \$host;'
chk "容器共享头透传 X-Forwarded-Host"    deploy/docker/ofm-proxy-headers.conf 'proxy_set_header X-Forwarded-Host \$host;'
cntchk "HTTP vhost 三个 location 齐全"   deploy/nginx/ofm.conf        'proxy_set_header X-Forwarded-Host \$host;' 3
cntchk "TLS vhost 三个 location 齐全"    deploy/nginx/ofm-tls.conf    'proxy_set_header X-Forwarded-Host \$host;' 3
nchk "透传未顶替 Host 回环重写（HTTP）" deploy/nginx/ofm.conf        'proxy_set_header Host +\$host'
nchk "透传未顶替 Host 回环重写（TLS）"  deploy/nginx/ofm-tls.conf    'proxy_set_header Host +\$host'

echo
echo "========================================"
printf "  通过 %s 项，失败 %s 项\n" "$pass" "$fail"
echo "========================================"
if [ "$fail" -eq 0 ]; then
  echo "结果：文档声明与实际代码/配置一致"
else
  echo "结果：存在 $fail 项不一致（上列 FAIL）"
fi
exit "$fail"
