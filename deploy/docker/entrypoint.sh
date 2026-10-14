#!/usr/bin/env bash
# 单容器监督入口：OFM 服务（仅回环）+ nginx（对外反代）同容器运行。
#
# 为什么同容器：上游 startStandalone 硬性只允许回环绑定（isLoopbackHost 校验），
# 容器网络的 DNAT 无法把发布端口流量送达 127.0.0.1，反代必须与其同网络命名空间。
#
# 为什么是「监督」而不是 exec：
#   上一版实现以 `exec nginx` 收尾，导致两个生产事故：
#   1) node 崩溃时 nginx 仍存活 → 容器不退 → 健康检查只标 unhealthy（Docker 不会因此重启）
#      → 服务永久 502，必须人工介入；
#   2) `docker stop` 的 SIGTERM 只送到 PID1(nginx)，node 收不到信号 → 被 SIGKILL
#      → service.lock 残留 → 下次启动 EEXIST 失败 → 容器陷入「反复重启反复失败」。
#   本版本改为监督模式：转发信号、任一子进程退出即退出容器（非零触发重启策略/告警）。
#
# 退出码约定（决定 restart 策略的行为，勿随意改动）：
#   0  —— 收到 SIGTERM/SIGINT 后优雅停止（docker stop / systemctl stop）
#   ≠0 —— 服务或反代异常退出，原样传播服务自身退出码（便于看 137=OOM、1=启动失败等）
set -uo pipefail

OFM_PORT="${OFM_PORT:-18900}"
OFM_PROXY_PORT="${OFM_PROXY_PORT:-8080}"
OFM_HOME="${OFM_HOME:-/data}"
OFM_EXTRA_ARGS="${OFM_EXTRA_ARGS:-}"
OFM_STARTUP_TIMEOUT="${OFM_STARTUP_TIMEOUT:-60}"
OFM_STOP_TIMEOUT="${OFM_STOP_TIMEOUT:-25}"
APP_DIR="/opt/ofm/app"
SCRIPTS_DIR="/opt/ofm/scripts"

# 渠道包会把「opencode 模型能力目录」缓存到 $DSH_HOME/cache/ 下，缓存路径只认 DSH_HOME。
# 不显式指定时它会落到 $HOME/.dsh —— 在 read_only: true 的容器里写失败（错误被吞掉，
# 表现是每次启动都重新拉一遍目录），且容器重建后丢失。
# 让 DSH_HOME 跟随 OFM_HOME：所有持久状态（settings / 凭据 / EAC 授权 / 统计 / 能力缓存）
# 一律落在数据目录这一个卷里，备份与迁移只需要搬一个目录。
export DSH_HOME="${DSH_HOME:-$OFM_HOME}"

log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] 错误：$*" >&2; exit 1; }

[ -f "$APP_DIR/cli.mjs" ] || die "未找到应用入口 $APP_DIR/cli.mjs（镜像构建异常）"
mkdir -p "$OFM_HOME" || die "无法创建数据目录 $OFM_HOME（检查卷挂载与权限）"

# ── 0) 陈旧锁判定 ───────────────────────────────────────────────
# 检测到活跃实例时拒绝启动（退出非零 → 由重启策略重试或告警），
# 确认是陈旧锁（进程已死 / PID 被复用）时自动清理，避免「必须人工删锁」。
if [ -f "$SCRIPTS_DIR/clear-stale-lock.sh" ]; then
  bash "$SCRIPTS_DIR/clear-stale-lock.sh" "$OFM_HOME" \
    || die "数据目录锁状态异常，终止启动（详见上方 [lock] 输出）"
fi

# ── 1) 启动服务（后台）─────────────────────────────────────────
log "启动服务：port=$OFM_PORT dataDir=$OFM_HOME dshHome=$DSH_HOME extraArgs='${OFM_EXTRA_ARGS}'"
# shellcheck disable=SC2086  # 有意展开为多个参数
node "$APP_DIR/cli.mjs" --port "$OFM_PORT" --data-dir "$OFM_HOME" $OFM_EXTRA_ARGS &
OFM_PID=$!

STOPPING=0
NGINX_PID=""

# 优雅停止：先 SIGTERM 服务（触发它的优雅退出与锁清理），再 SIGQUIT nginx。
# 兜底强杀是必要的：服务里可能有卡住的长连接/流式请求，若它忽略 SIGTERM，
# 容器会一直卡到 docker 的 stop_grace_period 用尽然后被 SIGKILL —— 又回到「残留锁」。
shutdown() {
  [ "$STOPPING" = 1 ] && return
  STOPPING=1
  log "收到停止信号：SIGTERM → 服务（优雅退出并清理锁），SIGQUIT → nginx"
  kill -TERM "$OFM_PID" 2>/dev/null || true
  [ -n "$NGINX_PID" ] && kill -QUIT "$NGINX_PID" 2>/dev/null || true
  # 子 shell 里 sleep 后强杀；disown 让它不算进 wait -n 的作业表，避免干扰监督判断
  ( sleep "$OFM_STOP_TIMEOUT"; kill -KILL "$OFM_PID" 2>/dev/null || true ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
trap shutdown TERM INT

# ── 2) 等待服务就绪 ────────────────────────────────────────────
i=0
while [ "$i" -lt "$OFM_STARTUP_TIMEOUT" ]; do
  if curl -fsS --max-time 3 "http://127.0.0.1:${OFM_PORT}/health" >/dev/null 2>&1; then
    log "服务就绪：http://127.0.0.1:${OFM_PORT}/health"
    break
  fi
  if ! kill -0 "$OFM_PID" 2>/dev/null; then
    RC=0; wait "$OFM_PID" || RC=$?
    # 就绪阶段就被停止信号打断属正常停止，不能报成「启动失败」
    if [ "$STOPPING" = 1 ]; then log "启动阶段收到停止信号，正常退出"; exit 0; fi
    echo "[entrypoint] 服务在启动阶段即退出（rc=$RC）。排查方向：" >&2
    echo "  1) 数据目录权限 / 锁状态（见上方 [lock] 输出）" >&2
    echo "  2) 端口 $OFM_PORT 被占且无法顺延" >&2
    echo "  3) 紧随本行上方的服务自身错误输出" >&2
    echo "  rc=137 通常是内存超限被 OOM Killer 杀掉，检查 NODE_OPTIONS 与内存限额" >&2
    exit "${RC:-1}"
  fi
  # 停止信号在 sleep 期间到达时，别等到超时才退
  [ "$STOPPING" = 1 ] && { log "启动阶段收到停止信号，正常退出"; exit 0; }
  i=$((i + 1))
  sleep 1
done
if [ "$i" -ge "$OFM_STARTUP_TIMEOUT" ]; then
  echo "[entrypoint] 服务在 ${OFM_STARTUP_TIMEOUT}s 内未就绪，终止容器" >&2
  keep_stopping=$STOPPING
  STOPPING=1                      # 抑制下面 kill 触发的二次 shutdown
  kill -TERM "$OFM_PID" 2>/dev/null || true
  sleep 2
  kill -KILL "$OFM_PID" 2>/dev/null || true
  [ "$keep_stopping" = 1 ] && exit 0
  exit 1
fi

# ── 3) 端口顺延检测 ────────────────────────────────────────────
# 服务在端口被占时会自动顺延并写回 settings.json.standalonePort，而 nginx 固定转发
# 到 $OFM_PORT —— 若发生顺延，反代会 502 且极难排查。此处显式拦截。
if [ -r "$OFM_HOME/settings.json" ]; then
  ACTUAL_PORT=$(node -e '
    const fs = require("node:fs");
    try {
      const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(s.standalonePort ?? ""));
    } catch { process.stdout.write(""); }
  ' "$OFM_HOME/settings.json" 2>/dev/null || true)
  if [ -n "${ACTUAL_PORT:-}" ] && [ "$ACTUAL_PORT" != "$OFM_PORT" ]; then
    die "端口发生顺延：期望 $OFM_PORT，实际 $ACTUAL_PORT。请释放该端口或显式设置 OFM_PORT，否则反代必然 502"
  fi
fi

# ── 4) 启动 nginx（前台于后台任务中）───────────────────────────
# 两份配置都要做端口变量替换：共享请求头片段里也带 ${OFM_PORT}（Host 头必须写成
# 127.0.0.1:<真实端口>，否则服务端的回环 Host 校验解析不出数字端口，管理端全 403）。
sed -e "s|\${OFM_PORT}|${OFM_PORT}|g" \
    -e "s|\${OFM_PROXY_PORT}|${OFM_PROXY_PORT}|g" \
    /etc/nginx/ofm-proxy-headers.conf > /tmp/ofm-proxy-headers.conf \
  || die "生成 nginx 请求头片段失败"
sed -e "s|\${OFM_PORT}|${OFM_PORT}|g" \
    -e "s|\${OFM_PROXY_PORT}|${OFM_PROXY_PORT}|g" \
    /etc/nginx/nginx.conf > /tmp/nginx.generated.conf || die "生成 nginx 配置失败"
log "启动 nginx：:${OFM_PROXY_PORT} → 127.0.0.1:${OFM_PORT}"
nginx -c /tmp/nginx.generated.conf -g 'daemon off;' &
NGINX_PID=$!

# ── 5) 监督循环：任一子进程退出即结束容器 ──────────────────────
RC=0
wait -n || RC=$?

# 关键分支：wait -n 也会被「已设置 trap 的信号」打断（返回 128+signo），
# 那种情况下并没有子进程死亡。若不做这个判断，一次正常的 docker stop 会被
# 误报成「nginx 已退出」，并让容器带着 143 退出码结束 —— 运维会被误导。
if [ "$STOPPING" = 1 ]; then
  log "停止流程进行中：等待子进程退出（上限 ${OFM_STOP_TIMEOUT}s）"
  wait "$OFM_PID" 2>/dev/null || true
  [ -n "$NGINX_PID" ] && wait "$NGINX_PID" 2>/dev/null || true
  log "已优雅停止"
  exit 0
fi

if kill -0 "$OFM_PID" 2>/dev/null; then
  log "nginx 已退出（rc=$RC）→ 停止服务，退出容器"
  kill -TERM "$OFM_PID" 2>/dev/null || true
  wait "$OFM_PID" 2>/dev/null || true
  [ "$RC" -eq 0 ] && RC=1   # 反代不该自行退出：即使 rc=0 也按异常处理
  exit "$RC"
fi

log "服务已退出（rc=$RC）→ 退出容器以触发重启策略/告警"
kill -QUIT "$NGINX_PID" 2>/dev/null || true
wait "$NGINX_PID" 2>/dev/null || true
# 服务退出码原样传播：非零 → Docker 重启并计入失败；0（多为 SIGTERM 优雅停止）→ 正常停止
exit "$RC"
