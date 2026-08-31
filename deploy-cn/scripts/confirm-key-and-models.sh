#!/usr/bin/env bash
set -uo pipefail
echo "=== 1. 验证新 DEEPSEEK_API_KEY 已注入 gateway 容器(脱敏,兼容 sh) ==="
docker exec deer-flow-gateway sh -c '
  K="${DEEPSEEK_API_KEY:-}"
  echo "  长度: ${#K}"
  echo "  前6位: $(printf "%s" "$K" | cut -c1-6)"
' 2>&1
echo ""
echo "=== 2. config.yaml 中的 api_key 引用(确认 DeepSeek + 2 ollama 都在) ==="
grep -n "api_key:" /opt/code/deer-flow/config.yaml 2>&1
echo ""
echo "=== 3. gateway 容器内 config.yaml 是否同步 ==="
docker exec deer-flow-gateway grep -n "api_key:" /app/backend/config.yaml 2>&1
echo ""
echo "=== 4. studio 是否仍存活 ==="
docker ps --filter name=deer-flow-studio --format '  {{.Names}}  {{.Status}}  {{.Ports}}' 2>&1
echo ""
echo "=== 5. 主栈入口 nginx(2026) ==="
curl -s -o /dev/null -w "  nginx: HTTP %{http_code}\n" --max-time 5 http://127.0.0.1:2026/ 2>&1
echo "CONFIRM_DONE"
