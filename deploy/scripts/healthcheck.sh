#!/usr/bin/env bash
# 健康检查：验证服务存活、API Key 生效、模型清单可用。
# 用法：bash deploy/scripts/healthcheck.sh [base_url] [data_dir]
#   base_url  默认 http://127.0.0.1:18900
#   data_dir  默认 /var/lib/ofm（用于读取 API Key）
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:18900}"
DATA_DIR="${2:-/var/lib/ofm}"
KEY_FILE="$DATA_DIR/settings.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> 1/4 liveness（免密钥）"
HEALTH=$(curl -fsS --max-time 10 "$BASE_URL/health") || fail "/health 不可达：$BASE_URL"
echo "    $HEALTH"
echo "$HEALTH" | grep -q '"ok":true' || fail "/health 未返回 ok:true"

if [[ -f "$KEY_FILE" ]]; then
  KEY=$(python3 -c "import json;print(json.load(open('$KEY_FILE'))['forwardKey'])" 2>/dev/null || true)
else
  KEY=""
fi

echo "==> 2/4 未授权请求必须被拒绝（期望 401）"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/v1/models")
[[ "$CODE" == "401" ]] || fail "/v1/models 无 Key 返回 $CODE（期望 401）"
echo "    HTTP 401 OK"

if [[ -z "$KEY" ]]; then
  echo "==> 跳过 3/4、4/4：未找到 $KEY_FILE（自定义数据目录请作为第二个参数传入）"
  exit 0
fi

echo "==> 3/4 模型清单（带 Key）"
MODELS=$(curl -fsS --max-time 15 -H "Authorization: Bearer $KEY" "$BASE_URL/v1/models") || fail "/v1/models 带 Key 请求失败"
COUNT=$(echo "$MODELS" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('data',[])))")
[[ "$COUNT" -gt 0 ]] || fail "模型清单为空"
echo "    $COUNT 个模型在线"

echo "==> 4/4 推理冒烟测试（kilo-auto/free，限额 32 token）"
REPLY=$(curl -fsS --max-time 60 -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"kilo-auto/free","messages":[{"role":"user","content":"say OK"}],"max_tokens":32}') \
  || fail "推理请求失败（可能上游暂不可达，属外部因素）"
echo "    $(echo "$REPLY" | head -c 200)"

echo ""
echo "PASS: 服务健康"
