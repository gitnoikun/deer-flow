#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="/opt/code/deer-flow"
cd "$REPO_ROOT"
ENV_FILE="$REPO_ROOT/.env"

# 与 deploy.sh 保持一致的路径插值变量(否则 compose 解析挂载会得到空值)
export DEER_FLOW_HOME="$REPO_ROOT/backend/.deer-flow"
export DEER_FLOW_REPO_ROOT="$REPO_ROOT"
export DEER_FLOW_CONFIG_PATH="$REPO_ROOT/config.yaml"
export DEER_FLOW_EXTENSIONS_CONFIG_PATH="$REPO_ROOT/extensions_config.json"

echo "=== 强制重建 gateway(重新读取 .env 注入新 key,不影响其他服务) ==="
docker compose --env-file "$ENV_FILE" -p deer-flow \
  -f "$REPO_ROOT/docker/docker-compose.yaml" \
  up -d --force-recreate --no-deps gateway 2>&1 | tail -20
echo ""
echo "=== 等待 gateway 就绪(/health) ==="
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8001/health 2>/dev/null || echo "000")
  echo "  [$i] /health -> $code"
  if [ "$code" = "200" ]; then echo "  gateway 已就绪"; break; fi
  sleep 2
done
echo ""
echo "=== 验证新 key 已注入 gateway 容器(脱敏) ==="
docker exec deer-flow-gateway sh -c 'printf "  DEEPSEEK_API_KEY 前6位=%s 长度=%s\n" "${DEEPSEEK_API_KEY:0:6}" "${#DEEPSEEK_API_KEY}"' 2>&1
echo ""
echo "=== 主栈容器状态 ==="
docker ps --filter name=deer-flow- --format '{{.Names}}  {{.Status}}' 2>&1
echo ""
echo "=== nginx 入口(2026) ==="
curl -s -o /dev/null -w "  nginx: HTTP %{http_code}\n" --max-time 5 http://127.0.0.1:2026/ 2>&1
echo "RESTART_KEY_DONE"
