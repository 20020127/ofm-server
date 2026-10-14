#!/bin/sh
# 陈旧锁检测与清理（Docker entrypoint 与 systemd ExecStartPre 共用）
#
# 背景：服务启动时以 O_EXCL 创建 <data_dir>/service.lock（内容 {"pid":N,"product":"..."}），
# 正常退出会删除它。若进程被 SIGKILL（容器超时强停、OOM、宿主断电），锁文件会残留，
# 下次启动直接 EEXIST 失败 —— 表现为「服务再也起不来，必须人工删锁」。
# 本脚本在每次启动前判定锁的真实性：确认锁中进程是否仍在运行、是否真的是本服务。
#
# 判定原则（宁可拒绝启动，也不并发双实例）：
#   pid 不存在                 → 陈旧残留，删除
#   pid 存活 且 cmdline 是本服务 → 真实占用，拒绝启动（exit 1，由守护层重试/告警）
#   pid 存活 但 cmdline 非本服务 → 原进程已死、PID 被系统复用，删除
#   完全读不到进程信息           → 保守拒绝，并打印人工处理指引
#
# 为什么存活判定要以 /proc 为准，而不是只靠 kill -0：
#   kill -0 在「进程存在但不属于当前用户」时返回 EPERM（同样是非零），
#   只看它就会把一个**活着的**实例误判为「已死」，然后删掉它的锁 ——
#   于是两个实例可能同时跑起来（第二个会因端口占用而顺延，反代却仍指向旧端口）。
#   这种情形在「有人手工用 sudo 起过一个实例」时就会发生。
#   因此：只要 /proc/<pid> 目录存在就认定存活（该目录项在任何权限下都可见），
#   kill -0 只作为「补一条存活证据」的兜底。
#
# 已知局限（部署前请确认，见 docs/PRODUCTION.md §7）：
#   /proc 以 hidepid=1/2 挂载时，跨用户的进程目录不可见；
#   非 Linux 平台的 /proc 可能是残缺模拟（例如 MSYS 只索引自己的 PID，
#   不含原生 Windows 进程）。此时判据一会漏判，本脚本会退化为清理策略。
#   本项目的两种部署形态都不受影响：容器内入口与服务同为 uid 10001，
#   systemd 单元的 User=ofm 使 ExecStartPre 与服务同用户。
#
# 用法：clear-stale-lock.sh <data_dir> [--force]
#   --force  跳过判定直接删锁（仅限人工确认无实例运行时使用，慎用）
# 退出码：0 = 可启动（无锁或已清理）；1 = 检测到活跃实例（不应启动）；2 = 用法错误
set -eu

DATA_DIR="${1:-}"
FORCE="${2:-}"

if [ -z "$DATA_DIR" ]; then
  echo "[lock] 用法：clear-stale-lock.sh <data_dir> [--force]" >&2
  exit 2
fi

LOCK="$DATA_DIR/service.lock"

if [ ! -e "$LOCK" ]; then
  exit 0
fi

if [ "$FORCE" = "--force" ]; then
  echo "[lock] --force 指定，直接移除 $LOCK" >&2
  rm -f "$LOCK"
  exit 0
fi

# 锁文件内容为 JSON，用 sed 提取 pid（避免依赖 python/jq）
PID=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$LOCK" 2>/dev/null | head -n 1)

if [ -z "$PID" ]; then
  echo "[lock] 锁文件不含可解析的 pid，按残留处理并移除：$LOCK" >&2
  rm -f "$LOCK"
  exit 0
fi

# 进程是否存活：两个判据取「或」。
#   判据一（权威）/proc/<pid> 存在 —— Linux 上等价于「进程存在」，且不受进程属主影响；
#   判据二（兜底）kill -0 成功 —— 覆盖 /proc 缺失或残缺的环境。
# 取「或」只会把 dead 误判成 alive（结果是拒绝删锁、要求人工介入），
# 绝不会把 alive 误判成 dead —— 与「宁可拒绝启动，也不并发双实例」的原则一致。
ALIVE=0
if [ -d "/proc/$PID" ]; then
  ALIVE=1
elif kill -0 "$PID" 2>/dev/null; then
  ALIVE=1
fi

if [ "$ALIVE" -eq 0 ]; then
  echo "[lock] 锁中 pid=$PID 未能找到对应进程（/proc 无此目录，kill -0 亦失败）→ 陈旧残留，移除锁" >&2
  echo "[lock]   如你确信该实例仍在运行，请先核实：ps -p $PID -o pid,args=" >&2
  rm -f "$LOCK"
  exit 0
fi

# 进程存活，确认身份：优先 /proc（Linux 恒有且不依赖 ps 实现），退化用 ps
if [ -r "/proc/$PID/cmdline" ]; then
  CMD=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)
else
  CMD=$(ps -p "$PID" -o args= 2>/dev/null || true)
fi

case "$CMD" in
  *cli.mjs*|*our-free-model*)
    echo "[lock] 检测到活跃服务实例：pid=$PID cmd=$CMD" >&2
    echo "[lock] 同一数据目录不允许并发启动，本次启动中止。" >&2
    echo "[lock] 若确认该进程异常僵死，请先用 kill -9 $PID 结束它，或确认无实例后执行：" >&2
    echo "[lock]   $0 '$DATA_DIR' --force" >&2
    exit 1
    ;;
  "")
    echo "[lock] pid=$PID 存活，但无法读取其命令行，无法判定是否为本服务。" >&2
    echo "[lock] 保守起见中止启动，请人工确认后处理（ps -p $PID -o args= 或 /proc/$PID/cmdline），" >&2
    echo "[lock] 确认该进程与本服务无关后执行：$0 '$DATA_DIR' --force" >&2
    exit 1
    ;;
  *)
    echo "[lock] pid=$PID 存活但不是本服务进程（PID 被系统复用），按陈旧残留处理" >&2
    echo "[lock]   该 pid 的进程：$CMD" >&2
    rm -f "$LOCK"
    exit 0
    ;;
esac
