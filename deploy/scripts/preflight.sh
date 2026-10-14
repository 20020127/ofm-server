#!/bin/sh
# 部署前环境预检（只读检测，不做任何修改）
#
# 用法：preflight.sh [data_dir] [port]
#   data_dir  默认 /var/lib/ofm
#   port      默认 18900（服务端口，冲突会导致服务自动顺延 -> nginx 502）
# 退出码：0 = 通过（允许存在 WARN）；1 = 存在 FAIL，不建议启动
#
# 设计要点：端口可用性用 Node 自身探测（服务本来就依赖 Node），
# 不依赖 ss/netstat/lsof 等在精简镜像中可能缺失的工具。
set -eu

DATA_DIR="${1:-/var/lib/ofm}"
PORT="${2:-18900}"

FAILS=0
WARNS=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }

echo "==> 1. 运行环境"
printf '  kernel=%s arch=%s\n' "$(uname -s 2>/dev/null || echo '?')" "$(uname -m 2>/dev/null || echo '?')"

if command -v node >/dev/null 2>&1; then
  NODE_VER=$(node -p 'process.versions.node' 2>/dev/null || echo '0.0.0')
  ok "node $NODE_VER"
  # 版本要求：^22.19.0 || >=24.0.0（与 app/package.json 的 engines 一致）
  case "$(node -p '
    const [maj, min] = process.versions.node.split(".").map(Number);
    (maj === 22 && min >= 19) || maj >= 24 ? "pass" : "fail"' 2>/dev/null)" in
    pass) ok "Node 版本满足 ^22.19.0 || >=24.0.0" ;;
    *)    fail "Node 版本不满足要求：$NODE_VER（需要 22.19+ 或 24+）" ;;
  esac
else
  fail "未找到 node，请先安装 Node.js 22.19+ 或 24+"
fi

echo "==> 2. 必需命令"
for c in sed tr kill rm mkdir; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else fail "缺少命令：$c"; fi
done
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
  ok "curl 或 wget 可用（健康检查需要）"
else
  warn "curl / wget 都不可用，健康检查脚本将无法执行"
fi

echo "==> 3. 数据目录（含明文 API Key 与账号凭据，权限需收紧）"
if [ -d "$DATA_DIR" ]; then
  ok "已存在：$DATA_DIR"
else
  warn "不存在（服务会自动创建）：$DATA_DIR"
fi
if [ -d "$DATA_DIR" ]; then
  if [ -w "$DATA_DIR" ]; then ok "可写"; else fail "不可写，服务无法保存 API Key 与凭据"; fi
  # 权限检查：组/其他 可读 视为风险（凭据文件泄露面）
  PERM=$(ls -ld "$DATA_DIR" 2>/dev/null | awk '{print $1}')
  case "$PERM" in
    d-----*|drwx------|drwxr-x---) ok "权限 $PERM" ;;
    *) warn "权限 $PERM 偏宽（建议 chmod 750 或 700，目录内含明文凭据）" ;;
  esac
fi

echo "==> 4. 端口 $PORT（服务只绑回环；端口被占会自动顺延，导致反代 502）"
if command -v node >/dev/null 2>&1; then
  PORT_STATE=$(node -e '
    const net = require("net");
    const port = Number(process.argv[1]);
    const srv = net.createServer();
    srv.once("error", e => { console.log(e.code === "EADDRINUSE" ? "busy" : "error:" + e.code); process.exit(0); });
    srv.listen(port, "127.0.0.1", () => { console.log("free"); srv.close(); });
  ' "$PORT" 2>/dev/null || echo "unknown")
  case "$PORT_STATE" in
    free) ok "127.0.0.1:$PORT 可用" ;;
    busy) fail "127.0.0.1:$PORT 已被占用（先排查：ss -ltnp | grep :$PORT）" ;;
    *)    warn "端口探测未得出结论（$PORT_STATE）" ;;
  esac
fi

echo "==> 5. 磁盘与内存"
if [ -d "$DATA_DIR" ]; then
  AVAIL_KB=$(df -Pk "$DATA_DIR" 2>/dev/null | tail -n 1 | awk '{print $4}')
  if [ -n "${AVAIL_KB:-}" ] && [ "$AVAIL_KB" -gt 0 ] 2>/dev/null; then
    AVAIL_MB=$((AVAIL_KB / 1024))
    if [ "$AVAIL_MB" -ge 512 ]; then ok "数据目录所在分区可用 ${AVAIL_MB}MB"
    else warn "数据目录所在分区仅剩 ${AVAIL_MB}MB，统计与凭据写入可能失败"; fi
  fi
fi
if [ -r /proc/meminfo ]; then
  MEM_MB=$(awk '/MemAvailable/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "${MEM_MB:-0}" -ge 512 ] 2>/dev/null; then
    ok "可用内存 ${MEM_MB}MB"
    if [ "$MEM_MB" -lt 1024 ] && [ -z "${NODE_OPTIONS:-}" ]; then
      warn "可用内存偏低且未设置 NODE_OPTIONS，建议 NODE_OPTIONS=--max-old-space-size=384"
    fi
  else
    warn "可用内存不足 512MB（${MEM_MB:-0}MB），建议提高或限制堆上限"
  fi
fi

echo "==> 6. 现有锁状态（只报告，不修改；清理由启动流程负责）"
if [ -e "$DATA_DIR/service.lock" ]; then
  warn "存在 $DATA_DIR/service.lock，启动流程会先判定是否为陈旧锁"
  printf '     内容：%s\n' "$(head -c 200 "$DATA_DIR/service.lock" 2>/dev/null || echo '?')"
else
  ok "无锁文件"
fi

echo ""
if [ "$FAILS" -gt 0 ]; then
  echo "预检结果：FAIL（$FAILS 项阻塞，$WARNS 项警告）—— 请先解决 FAIL 项再启动"
  exit 1
fi
echo "预检结果：通过（$WARNS 项警告）"
exit 0
