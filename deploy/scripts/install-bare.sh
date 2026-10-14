#!/usr/bin/env bash
# 裸机安装脚本（Debian/Ubuntu/RHEL 系，systemd 环境）。
# 用法：sudo bash deploy/scripts/install-bare.sh
# 作用：创建 ofm 用户与数据目录 → 安装应用到 /opt/ofm → 安装 systemd unit → 启动。
set -euo pipefail

PREFIX="${PREFIX:-/opt/ofm}"
DATA_DIR="${DATA_DIR:-/var/lib/ofm}"
SERVICE_USER="${SERVICE_USER:-ofm}"
PORT="${PORT:-18900}"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行：sudo bash deploy/scripts/install-bare.sh" >&2
  exit 1
fi

echo "==> 检查 Node.js（要求 ^22.19.0 或 >=24.0.0）"
if ! command -v node >/dev/null 2>&1; then
  echo "未找到 node。安装方式（任选其一）：" >&2
  echo "  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt install -y nodejs" >&2
  echo "  # 或 nvm：curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash" >&2
  exit 1
fi
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
NODE_VER=$(node -p 'process.versions.node')
if [[ "$NODE_MAJOR" -lt 22 ]] || { [[ "$NODE_MAJOR" -eq 22 ]] && [[ "$(node -p 'process.versions.node.split(".")[1]')" -lt 19 ]]; }; then
  echo "Node 版本过低：$NODE_VER（需要 22.19+ 或 24+）" >&2
  exit 1
fi
echo "    node $NODE_VER OK"

echo "==> 创建用户与目录"
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
mkdir -p "$PREFIX" "$DATA_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
chmod 750 "$DATA_DIR"

echo "==> 安装应用到 $PREFIX"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rm -rf "$PREFIX/app"
mkdir -p "$PREFIX/app"
cp -r "$SCRIPT_DIR/app/." "$PREFIX/app/"
cp "$SCRIPT_DIR/README.md" "$PREFIX/README.md" 2>/dev/null || true
chown -R root:root "$PREFIX/app"

echo "==> 安装 systemd unit"
sed -e "s|/var/lib/ofm|$DATA_DIR|g" -e "s|--port 18900|--port $PORT|g" \
  "$SCRIPT_DIR/deploy/systemd/ofm.service" > "/etc/systemd/system/ofm.service"
systemctl daemon-reload
systemctl enable --now ofm

echo ""
echo "==> 完成。常用命令："
echo "  查看状态：  systemctl status ofm"
echo "  看日志：    journalctl -u ofm -f"
echo "  一次性登录链接（管理页面）：journalctl -u ofm -n 20 --no-pager | grep 管理页面"
echo "  API Key：   cat $DATA_DIR/settings.json"
echo ""
echo "==> 下一步：配置 nginx 反代（deploy/nginx/ofm.conf 或 ofm-tls.conf）"
