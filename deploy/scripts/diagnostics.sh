#!/bin/sh
# 一键诊断信息采集（只读；用于故障工单、上线验收、排错定位）
#
# 用法：diagnostics.sh [data_dir] [mode]
#   data_dir  默认 /var/lib/ofm
#   mode      bare（默认，读 journalctl）| docker（读 docker logs ofm）
#
# 退出码：0 = 未发现高危凭据，可安全外发
#         1 = 命中高危凭据模式，禁止直接外发（见末尾「凭据泄漏自检」）
#         2 = 用法/环境错误
#
# 安全设计：
#   1) 本脚本**不会**打印 settings.json / channel-credentials.json / eac-user.json 的内容
#      （其中含明文 API Key、账号凭据与授权令牌），只列出文件名与权限；
#   2) 但日志、环境变量、锁文件仍可能夹带敏感内容，因此采集完成后会对**整份快照**
#      做一次自动泄漏自检，并在结尾给出明确结论与退出码。
#      这样"可不可以外发"不再依赖执行者的自觉。
set -eu

DATA_DIR="${1:-/var/lib/ofm}"
MODE="${2:-bare}"

# 整份快照先落到临时文件，便于末尾做泄漏自检。
SNAP="${TMPDIR:-/tmp}/ofm-diag-$$.txt"
trap 'rm -f "$SNAP"' EXIT INT TERM

# ── 采集（全部输出重定向进快照文件）─────────────────────────────
{
echo "==================== Our Free Model 诊断快照 ===================="
echo "采集时间 : $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC) / TZ=${TZ:-未设置}"
echo "主机     : $(hostname 2>/dev/null || echo '?')"
echo "内核     : $(uname -srm 2>/dev/null || echo '?')"

echo ""
echo "---- Node 与运行环境 ----"
if command -v node >/dev/null 2>&1; then
  echo "node     : $(node -p 'process.versions.node' 2>/dev/null)"
  echo "NODE_OPTIONS : ${NODE_OPTIONS:-（未设置）}"
else
  echo "node     : 未找到"
fi
echo "NODE_ENV : ${NODE_ENV:-（未设置）}"
echo "OFM_HOME : ${OFM_HOME:-（未设置）}"
echo "DSH_HOME : ${DSH_HOME:-（未设置，将回退到 ~/.dsh —— 只读根文件系统下会写失败）}"
echo "OFM_PORT : ${OFM_PORT:-（未设置，默认 18900）}"

echo ""
echo "---- 进程 ----"
if command -v ps >/dev/null 2>&1; then
  ps -eo pid,ppid,etimes,rss,args 2>/dev/null | grep -E 'cli\.mjs|nginx|PID' | grep -v grep || echo "未发现 cli.mjs / nginx 进程"
else
  echo "ps 不可用，跳过"
fi

echo ""
echo "---- 端口监听 ----"
if command -v ss >/dev/null 2>&1; then
  ss -ltnp 2>/dev/null | grep -E ':18900|:8080|:80 |:443|State' || echo "未发现监听端口（或权限不足）"
elif command -v netstat >/dev/null 2>&1; then
  netstat -ltnp 2>/dev/null | grep -E ':18900|:8080|:80 |:443|Proto' || echo "未发现监听端口"
else
  echo "ss / netstat 均不可用，跳过"
fi

echo ""
echo "---- 数据目录 $DATA_DIR ----"
if [ -d "$DATA_DIR" ]; then
  ls -ld "$DATA_DIR" 2>/dev/null || true
  echo "文件（仅名称与权限，不显示内容）："
  ls -la "$DATA_DIR" 2>/dev/null | sed '1d' || true
  echo "磁盘占用 : $(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')"
  if [ -e "$DATA_DIR/service.lock" ]; then
    # 锁文件内容仅 {pid, product}，无凭据，可安全打印
    echo "锁文件   : 存在 -> $(head -c 200 "$DATA_DIR/service.lock" 2>/dev/null)"
    LOCK_PID=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/service.lock" 2>/dev/null | head -1)
    if [ -n "${LOCK_PID:-}" ]; then
      # 与 clear-stale-lock.sh 同口径：/proc 权威，kill -0 兜底，取「或」。
      # 注意 /proc 在 hidepid=2 或非 Linux 平台可能漏判，故措辞留有余地而非断言。
      if [ -d "/proc/$LOCK_PID" ] || kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "锁归属   : pid $LOCK_PID 判定为存活（实例应在运行）"
      else
        echo "锁归属   : pid $LOCK_PID 未找到（判为陈旧残留，下次启动会自动清理）"
        echo "           若确信实例仍在运行，请核实：ps -p $LOCK_PID -o pid,args="
      fi
    fi
  else
    echo "锁文件   : 无"
  fi
  # 可写性
  if [ -w "$DATA_DIR" ]; then echo "可写性   : 可写"; else echo "可写性   : 不可写（异常）"; fi
else
  echo "数据目录不存在"
fi

echo ""
echo "---- 资源 ----"
if [ -r /proc/loadavg ]; then awk '{print "负载(1/5/15m): "$1" / "$2" / "$3}' /proc/loadavg; fi
if [ -r /proc/meminfo ]; then
  awk '/MemTotal|MemAvailable/ {printf "%s: %d MB\n", $1, $2/1024}' /proc/meminfo
fi
if [ -r /sys/fs/cgroup/memory.max ]; then
  echo "cgroup 内存上限: $(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
  echo "cgroup 内存上限: $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
fi
df -Ph "$DATA_DIR" 2>/dev/null | tail -n +1 || df -Ph / 2>/dev/null | tail -n +1

echo ""
echo "---- 最近日志（末 40 行）----"
case "$MODE" in
  docker)
    if command -v docker >/dev/null 2>&1; then
      docker logs --tail 40 ofm 2>&1 || echo "读取 docker 日志失败"
    else
      echo "docker 命令不可用"
    fi
    ;;
  *)
    if command -v journalctl >/dev/null 2>&1; then
      journalctl -u ofm -n 40 --no-pager 2>&1 || echo "读取 journald 日志失败"
    else
      echo "journalctl 不可用（容器环境请用第二个参数 docker）"
    fi
    ;;
esac

echo ""
echo "==================== 快照结束 ===================="
} > "$SNAP" 2>&1

# 打印快照（内容只出现在本机终端，不会自动外发）
cat "$SNAP"

# ── 凭据泄漏自检 ────────────────────────────────────────────────
# 对整份快照做兜底扫描。维护本脚本时若不小心加入了会打印明文凭据的段落，
# 这一步会立刻拦下来，而不是等凭据被贴进工单系统之后才发现。
#
# 高危模式：出现即禁止外发
#   ofm-<32 位 base64url>  = 本服务下发的 API Key（app 内 generateKey()：ofm- + 24 字节 base64url）
#   eyJ....               = JWT（EAC 授权、渠道 OAuth 令牌）
#   sk-...                = 常见第三方 API Key 前缀
# 注意：`ofm-user` / `ofm-timestamp` / `ofm-signature` 是协议头名，{20,} 的长度门槛可避免误报。
PAT_HIGH='forwardKey|client_secret|clientSecret|client_id|access_key|accessKey|refreshToken|refresh_token|"password"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9_-]{16,}|ofm-[A-Za-z0-9_-]{20,}'
# 一次性登录令牌：约 10 分钟有效，风险低但仍建议打码（服务启动日志里会出现）
PAT_OTP='#login='

HIGH=$(grep -nE "$PAT_HIGH" "$SNAP" 2>/dev/null | cut -d: -f1 | tr '\n' ' ' || true)
OTP=$(grep -nE "$PAT_OTP" "$SNAP" 2>/dev/null | cut -d: -f1 | tr '\n' ' ' || true)

echo ""
echo "==================== 凭据泄漏自检 ===================="
echo "扫描范围 : 上方整份快照（$(wc -l < "$SNAP" 2>/dev/null | tr -d ' ') 行）"
if [ -n "$HIGH" ]; then
  echo "高危命中 : 第 $HIGH 行"
  echo "结论     : ❌ 命中疑似凭据 —— 禁止直接外发！"
  echo "处置     : 只保留本「凭据泄漏自检」结论段，或用 sed 删除上述行后再提交。"
  exit 1
fi
if [ -n "$OTP" ]; then
  echo "提示     : 第 $OTP 行含一次性登录令牌（约 10 分钟有效）。风险低，仍建议打码后外发。"
fi
echo "结论     : ✅ 未发现高危凭据，可安全外发。"
exit 0
