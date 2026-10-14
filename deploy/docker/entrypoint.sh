#!/bin/sh
# 单容器入口：先起 OFM 服务（只绑回环），就绪后起 nginx 反代（前台）。
# 为什么同容器：上游 startStandalone 硬性只允许回环绑定（isLoopbackHost 校验），
# 容器网络的 DNAT 无法把发布端口流量送到 127.0.0.1，反代必须与其同网络命名空间。
set -e

OFM_PORT="${OFM_PORT:-18900}"
OFM_PROXY_PORT="${OFM_PROXY_PORT:-8080}"
OFM_HOME="${OFM_HOME:-/data}"

mkdir -p "$OFM_HOME"

# 1) 启动应用（后台）。--no-refresh 可加在 OFM_EXTRA_ARGS 中控制启动刷新行为。
# shellcheck disable=SC2086
node /opt/ofm/app/cli.mjs --port "$OFM_PORT" --data-dir "$OFM_HOME" $OFM_EXTRA_ARGS &
OFM_PID=$!

term_handler() {
  echo "[entrypoint] SIGTERM received, stopping..."
  kill -TERM "$OFM_PID" 2>/dev/null || true
  wait "$OFM_PID" 2>/dev/null || true
  nginx -s quit -c /tmp/nginx.generated.conf 2>/dev/null || true
  exit 0
}
trap term_handler TERM INT

# 2) 等待服务端口就绪（最多 30 秒）
i=0
while [ "$i" -lt 30 ]; do
  if curl -fsS "http://127.0.0.1:${OFM_PORT}/health" >/dev/null 2>&1; then
    echo "[entrypoint] OFM service ready on 127.0.0.1:${OFM_PORT}"
    break
  fi
  if ! kill -0 "$OFM_PID" 2>/dev/null; then
    echo "[entrypoint] OFM service exited during startup" >&2
    wait "$OFM_PID" || true
    exit 1
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$i" -ge 30 ]; then
  echo "[entrypoint] OFM service did not become ready in 30s" >&2
  kill -TERM "$OFM_PID" 2>/dev/null || true
  exit 1
fi

# 3) 生成 nginx 配置（替换端口变量）并以前台 daemon off 运行
sed -e "s|\${OFM_PORT}|${OFM_PORT}|g" \
    -e "s|\${OFM_PROXY_PORT}|${OFM_PROXY_PORT}|g" \
    /etc/nginx/nginx.conf > /tmp/nginx.generated.conf
echo "[entrypoint] nginx listening on :${OFM_PROXY_PORT}"
exec nginx -c /tmp/nginx.generated.conf -g 'daemon off;'
