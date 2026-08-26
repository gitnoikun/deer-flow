#!/usr/bin/env bash
#
# 停止并删除 DeerFlow 容器
# 等价于 ./deploy.sh down 的简写。
#
# 用法：./stop.sh  （必须在仓库根目录运行）

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/.env"
DOCKER_DIR="$REPO_ROOT/docker"

if [ -f "$ENV_FILE" ]; then
    docker compose --env-file "$ENV_FILE" -p deer-flow -f "$DOCKER_DIR/docker-compose.yaml" down
else
    docker compose -p deer-flow -f "$DOCKER_DIR/docker-compose.yaml" down
fi

echo "✓ 容器已停止并删除。"
echo "  如需删除数据卷：docker compose -p deer-flow down -v（慎用，会清 redis / .deer-flow）"
