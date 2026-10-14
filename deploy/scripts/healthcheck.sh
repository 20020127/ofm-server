#!/usr/bin/env bash
# 健康检查：验证服务存活、鉴权生效、模型清单可用（可选推理冒烟）。
#
# 用法：healthcheck.sh [base_url] [data_dir] [--quick|--full]
#   base_url   默认 http://127.0.0.1:18900（容器内应传 http://127.0.0.1:8080 走反代）
#   data_dir   默认 /var/lib/ofm（读取 API Key 用）
#   --quick    只做 liveness + 鉴权拦截（不消耗上游额度，适合监控/探针高频调用）
#   --full     默认：额外校验模型清单 + 一次真实推理（32 token 级）
#
# 退出码：0 = 健康；1 = 不健康；2 = 用法错误
# 监控接入建议：外部探针用 --quick 每 30s；业务级巡检用 --full 每 5-15 分钟。
#
# 依赖：只用 curl + node。node 是本项目的硬性运行前提，必然存在；
# 刻意不用 python3/jq —— 最小化安装的服务器与容器镜像里都没有它们，
# 缺失时会因 set -e 把「解析工具不存在」误报成「服务不健康」。
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:18900}"
DATA_DIR="${2:-/var/lib/ofm}"
MODE="${3:---full}"

KEY_FILE="$DATA_DIR/settings.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || fail "未找到 node（本脚本依赖 node 解析 JSON；请确认运行环境）"

case "$MODE" in
  --quick|--full) ;;
  *) echo "用法：healthcheck.sh [base_url] [data_dir] [--quick|--full]" >&2; exit 2 ;;
esac

# 从 stdin 读 JSON，输出顶层某个布尔字段是否为 true / 数组长度
json_bool() {  # json_bool <stdin-json> <field>  → 退出 0 表示字段为 true
  node -e '
    let raw = "";
    process.stdin.on("data", c => { raw += c });
    process.stdin.on("end", () => {
      try { process.exit(JSON.parse(raw)[process.argv[1]] === true ? 0 : 1) } catch { process.exit(1) }
    });
  ' "$1"
}
json_len() {   # json_len <stdin-json> <array-field> → 打印长度，0 表示取不到
  node -e '
    let raw = "";
    process.stdin.on("data", c => { raw += c });
    process.stdin.on("end", () => {
      try {
        const v = JSON.parse(raw)[process.argv[1]];
        process.stdout.write(String(Array.isArray(v) ? v.length : 0));
      } catch { process.stdout.write("0") }
    });
  ' "$1"
}

echo "==> 1/3 liveness（免密钥，探针口径）"
HEALTH=$(curl -fsS --max-time 10 "$BASE_URL/health") || fail "/health 不可达：$BASE_URL（进程挂了，或反代 502）"
echo "    $HEALTH"
printf '%s' "$HEALTH" | json_bool ok || fail "/health 未返回 ok:true"

echo "==> 2/3 鉴权拦截（无 Key 必须 401）"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/v1/models")
[[ "$CODE" == "401" ]] || fail "/v1/models 无 Key 返回 $CODE（期望 401；若为 200 说明鉴权失效，立即排查）"
echo "    HTTP 401 OK"

echo "==> 3/3 数据目录与锁状态"
KEY=""
if [[ -f "$KEY_FILE" ]]; then
  # 只读 forwardKey，绝不打印文件其它内容（同目录下有明文渠道凭据）
  KEY=$(node -e '
    try {
      const s = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(typeof s.forwardKey === "string" ? s.forwardKey : "");
    } catch { process.stdout.write("") }
  ' "$KEY_FILE")
  [[ -n "$KEY" ]] && echo "    API Key 可读取" || fail "$KEY_FILE 存在但无法解析 forwardKey"
  if [[ -w "$DATA_DIR" ]]; then echo "    数据目录可写"; else fail "$DATA_DIR 不可写（统计与凭据写入会失败）"; fi
else
  echo "    未找到 $KEY_FILE（自定义数据目录请作为第二个参数传入）"
fi

if [[ "$MODE" == "--quick" ]]; then
  echo ""
  echo "PASS: 存活与鉴权正常（--quick 模式，未校验模型与推理）"
  exit 0
fi

if [[ -z "$KEY" ]]; then
  echo ""
  echo "PASS: 存活与鉴权正常（未提供 API Key，跳过模型与推理校验）"
  exit 0
fi

echo "==> 附加 4/5 模型清单（带 Key）"
MODELS=$(curl -fsS --max-time 20 -H "Authorization: Bearer $KEY" "$BASE_URL/v1/models") || fail "/v1/models 带 Key 请求失败"
COUNT=$(printf '%s' "$MODELS" | json_len data)
[[ "$COUNT" -gt 0 ]] || fail "模型清单为空（上游全部不可达或目录刷新失败）"
echo "    $COUNT 个模型在线"

echo "==> 附加 5/5 推理冒烟（kilo-auto/free，32 token）"
REPLY=$(curl -fsS --max-time 60 -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"kilo-auto/free","messages":[{"role":"user","content":"say OK"}],"max_tokens":32}') \
  || fail "推理请求失败（上游暂不可达属外部因素；本地服务本身仍健康）"
echo "    $(printf '%s' "$REPLY" | head -c 200)"

echo ""
echo "PASS: 服务健康（存活 / 鉴权 / 目录 / 模型 / 推理 全通过）"
