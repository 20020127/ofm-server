#!/usr/bin/env bash
# 就绪等待：轮询 /health 直到服务真正开始应答，或超时。
#
# 用途：systemd 的 ExecStartPost。Type=simple 的单元在进程 fork 出来那一刻就被算作
# 「已启动」，而本服务还要初始化渠道 Worker、刷新模型目录（数十秒）——没有这一步时，
# `systemctl start ofm && curl ...` 必然失败，部署脚本与自动化会误判成服务坏掉。
#
# 用法：wait-ready.sh [base_url] [timeout_seconds]
#   base_url          默认 http://127.0.0.1:18900
#   timeout_seconds   默认 60
#
# 退出码：0 = 已就绪；1 = 超时或进程在等待期间消失；2 = 用法错误
#
# 注意：只用 curl，不做鉴权校验、不消耗任何上游额度（/health 是本地免密钥接口）。
set -uo pipefail

BASE_URL="${1:-http://127.0.0.1:18900}"
TIMEOUT="${2:-60}"

case "$TIMEOUT" in
  ''|*[!0-9]*) echo "用法：wait-ready.sh [base_url] [timeout_seconds]" >&2; exit 2 ;;
esac

i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  if curl -fsS --max-time 3 "$BASE_URL/health" >/dev/null 2>&1; then
    echo "[ready] 服务已就绪（等待 ${i}s）：$BASE_URL/health"
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

echo "[ready] 等待 ${TIMEOUT}s 后 /health 仍不可达：$BASE_URL" >&2
echo "[ready] 排查顺序：journalctl -u ofm -n 80 --no-pager" >&2
echo "[ready]            /opt/ofm/scripts/diagnostics.sh /var/lib/ofm bare" >&2
exit 1
