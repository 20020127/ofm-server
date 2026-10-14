#!/usr/bin/env bash
# 裸机安装脚本（Debian/Ubuntu/RHEL 系，systemd 环境）。
#
# 用法：sudo bash deploy/scripts/install-bare.sh
#   可用环境变量覆盖：
#     PREFIX=/opt/ofm  DATA_DIR=/var/lib/ofm  SERVICE_USER=ofm  PORT=18900
#
# 作用：检查 node → 创建用户与数据目录 → 安装应用到 PREFIX → 安装运维脚本
#       → 安装 systemd unit 与定时探针 → 安装 journald 容量上限 → 启动并验证就绪。
#
# 说明：本脚本可重复执行（幂等）。重复执行只覆盖代码与单元，不动数据目录内容。
set -euo pipefail

PREFIX="${PREFIX:-/opt/ofm}"
DATA_DIR="${DATA_DIR:-/var/lib/ofm}"
SERVICE_USER="${SERVICE_USER:-ofm}"
PORT="${PORT:-18900}"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行：sudo bash deploy/scripts/install-bare.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "==> 检查 Node.js（要求 ^22.19.0 或 >=24.0.0）"
if ! command -v node >/dev/null 2>&1; then
  echo "未找到 node。安装方式（任选其一）：" >&2
  echo "  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt install -y nodejs" >&2
  echo "  # 或 nvm：curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash" >&2
  exit 1
fi
NODE_BIN="$(command -v node)"
NODE_VER="$(node -p 'process.versions.node')"
# 用 node 自己判断版本，避免不同 shell 的比较口径差异：^22.19.0 || >=24.0.0
if ! node -e '
  const [maj, min] = process.versions.node.split(".").map(Number);
  process.exit((maj === 22 && min >= 19) || maj >= 24 ? 0 : 1);
'; then
  echo "Node 版本不满足要求：$NODE_VER（需要 22.19+ 或 24+）" >&2
  exit 1
fi
echo "    node $NODE_VER OK（$NODE_BIN）"

echo "==> 创建用户与数据目录"
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  # --system：无登录 shell、无密码过期策略；home 指向数据目录便于人工排查
  useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
mkdir -p "$PREFIX" "$DATA_DIR"
# 数据目录 0700：内含明文渠道凭据与 API Key，不放给同机其它用户
chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
chmod 700 "$DATA_DIR"

echo "==> 安装应用到 $PREFIX/app"
rm -rf "$PREFIX/app"
mkdir -p "$PREFIX/app"
cp -r "$SCRIPT_DIR/app/." "$PREFIX/app/"

echo "==> 安装运维脚本到 $PREFIX/scripts"
mkdir -p "$PREFIX/scripts"
cp "$SCRIPT_DIR/deploy/scripts/"*.sh "$PREFIX/scripts/"
chmod 0755 "$PREFIX/scripts/"*.sh

# 文档随单元一起装：ofm.service 的 Documentation= 指向这些路径
cp "$SCRIPT_DIR/README.md" "$PREFIX/README.md" 2>/dev/null || true
if [[ -d "$SCRIPT_DIR/docs" ]]; then
  mkdir -p "$PREFIX/docs"
  cp -r "$SCRIPT_DIR/docs/." "$PREFIX/docs/"
fi

# 代码与脚本 root 所有、服务用户只读：服务被攻破也改不了自己下次启动要执行的代码
chown -R root:root "$PREFIX"
chmod -R go-w "$PREFIX"

echo "==> 安装 systemd unit"
# 三处替换：安装前缀、数据目录、node 绝对路径（unit 里写死 /usr/bin/node 会在
# nvm / nodebrew 等安装方式下指向不存在的文件，服务起不来）。
sed -e "s|/opt/ofm|$PREFIX|g" \
    -e "s|/var/lib/ofm|$DATA_DIR|g" \
    -e "s|/usr/bin/node|$NODE_BIN|g" \
    -e "s|--port 18900|--port $PORT|g" \
    -e "s|127.0.0.1:18900|127.0.0.1:$PORT|g" \
    "$SCRIPT_DIR/deploy/systemd/ofm.service" > /etc/systemd/system/ofm.service

echo "==> 安装定时健康探针"
sed -e "s|/opt/ofm|$PREFIX|g" \
    -e "s|/var/lib/ofm|$DATA_DIR|g" \
    -e "s|127.0.0.1:18900|127.0.0.1:$PORT|g" \
    "$SCRIPT_DIR/deploy/systemd/ofm-healthcheck.service" > /etc/systemd/system/ofm-healthcheck.service
cp "$SCRIPT_DIR/deploy/systemd/ofm-healthcheck.timer" /etc/systemd/system/ofm-healthcheck.timer

echo "==> 安装 journald 容量上限（防止日志把数据盘写满）"
mkdir -p /etc/systemd/journald.conf.d
if [[ -e /etc/systemd/journald.conf.d/ofm.conf ]]; then
  echo "    已存在 /etc/systemd/journald.conf.d/ofm.conf，保留现有配置不动"
else
  cp "$SCRIPT_DIR/deploy/systemd/journald-ofm.conf" /etc/systemd/journald.conf.d/ofm.conf
  systemctl restart systemd-journald || true
fi

if [[ -d /etc/logrotate.d ]]; then
  # 默认惰性：只在 /var/log/ofm/ 存在日志文件时才起作用（missingok）
  cp "$SCRIPT_DIR/deploy/systemd/ofm.logrotate" /etc/logrotate.d/ofm
fi

echo "==> 可选覆盖项模板 /etc/default/ofm"
if [[ ! -e /etc/default/ofm ]]; then
  cat > /etc/default/ofm <<EOF
# Our Free Model 可调项（ofm.service 通过 EnvironmentFile 读取）
# 改完执行：systemctl restart ofm
#
# 出站代理（访问 Google/Gemini 等渠道时按需）
# HTTPS_PROXY=http://127.0.0.1:7890
# NO_PROXY=127.0.0.1,localhost
#
# 额外启动参数，例如跳过启动时的目录刷新： --no-refresh
# OFM_EXTRA_ARGS=
#
# Node 堆上限，应与 ofm.service 里的 MemoryMax 一起调整（约取其 50%~60%）
# NODE_OPTIONS=--max-old-space-size=1024
EOF
  chmod 0644 /etc/default/ofm
  echo "    已生成 /etc/default/ofm"
fi

echo "==> 校验单元文件"
systemctl daemon-reload
if command -v systemd-analyze >/dev/null 2>&1; then
  # 校验失败只告警不中断：不同发行版的 systemd 版本对部分加固项支持不一
  systemd-analyze verify /etc/systemd/system/ofm.service 2>&1 | sed 's/^/    /' || true
fi

echo "==> 启动服务"
systemctl enable --now ofm
# 定时器与服务分开启用：即使服务启动失败，也应能看到探针的失败记录
systemctl enable --now ofm-healthcheck.timer

echo ""
echo "==> 就绪验证（由 unit 的 ExecStartPost 完成，这里再确认一次）"
if "$PREFIX/scripts/healthcheck.sh" "http://127.0.0.1:$PORT" "$DATA_DIR" --quick; then
  echo ""
  echo "==> 完成。常用命令："
else
  echo ""
  echo "!!! 健康检查未通过，请查看：journalctl -u ofm -n 80 --no-pager" >&2
  echo "!!! 诊断快照：$PREFIX/scripts/diagnostics.sh $DATA_DIR bare" >&2
fi
echo "  查看状态：  systemctl status ofm"
echo "  看日志：    journalctl -u ofm -f"
echo "  探针记录：  journalctl -u ofm-healthcheck --since '1 hour ago'"
echo "  下次探测：  systemctl list-timers ofm-healthcheck.timer"
echo "  一次性登录链接（管理页面）：journalctl -u ofm -n 20 --no-pager | grep 管理页面"
echo "  API Key：   仅写在 $DATA_DIR/settings.json（该目录 0700，含明文凭据，备份须加密）"
echo ""
echo "==> 下一步：配置 nginx 反代（deploy/nginx/ofm.conf 或 ofm-tls.conf）"
