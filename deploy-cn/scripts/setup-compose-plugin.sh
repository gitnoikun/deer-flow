#!/usr/bin/env bash
# 把已存在的 docker-compose v2 二进制注册为 `docker compose` 插件
set -e

DOCKER_BIN="$(command -v docker || true)"
COMPOSE_BIN="$(command -v docker-compose || true)"

if [ -z "$DOCKER_BIN" ]; then
    echo "✗ 未找到 docker 二进制"; exit 1
fi
if [ -z "$COMPOSE_BIN" ]; then
    echo "✗ 未找到 docker-compose 二进制"; exit 1
fi
if [ ! -x "$COMPOSE_BIN" ]; then
    echo "✗ $COMPOSE_BIN 不可执行"; exit 1
fi

# 找到 docker 的 cli-plugins 目录
# 常见位置（按优先级）：
PLUGIN_DIR=""
for d in /usr/local/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins /usr/lib/docker/cli-plugins /usr/local/bin/docker/cli-plugins; do
    if [ -d "$d" ]; then
        PLUGIN_DIR="$d"
        break
    fi
done
if [ -z "$PLUGIN_DIR" ]; then
    # 没有现成目录，用默认的 /usr/local/lib/docker/cli-plugins
    PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"
    mkdir -p "$PLUGIN_DIR"
fi

echo "检测到 docker-compose: $COMPOSE_BIN"
echo "插件目录: $PLUGIN_DIR"

# 软链 docker-compose -> cli-plugins/docker-compose
ln -sf "$COMPOSE_BIN" "$PLUGIN_DIR/docker-compose"
chmod +x "$PLUGIN_DIR/docker-compose" 2>/dev/null || true

echo "✓ 已注册 compose 插件"
echo "验证:"
docker compose version
