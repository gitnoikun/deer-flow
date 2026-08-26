#!/usr/bin/env bash
#
# DeerFlow 国内服务器部署脚本
#
# 用法：
#   ./deploy.sh              # 构建 + 启动（推荐）
#   ./deploy.sh build        # 只构建镜像
#   ./deploy.sh start        # 从已构建镜像启动（不重新构建）
#   ./deploy.sh down         # 停止并删除容器
#   ./deploy.sh logs         # 查看服务日志（后接服务名可选，如 logs gateway）
#
# 说明：
#   - 必须在仓库根目录运行（脚本会自动 cd 到仓库根）。
#   - 复用官方 docker/docker-compose.yaml，不重复维护服务定义。
#   - 从仓库根 .env 读取镜像源（APT_MIRROR / UV_INDEX_URL / NPM_REGISTRY / UV_IMAGE 等）
#     并传给 docker build，解决国内拉不到构建依赖的问题。
#   - 自动检测沙箱模式（local / aio / provisioner）：local 不需要沙箱镜像。
#
# 依赖：docker + docker compose v2（支持 --wait）。

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/.env"
DOCKER_DIR="$REPO_ROOT/docker"

# ── 颜色 ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

run_in_repo() { echo -e "${BLUE}[deer-flow]${NC} $*"; }

# ── 读取 .env 单个值（与 docker compose --env-file 的取法保持一致）────────────
read_env() {
    local key="$1"
    local line value
    if [ -n "${!key+x}" ]; then printf '%s' "${!key}"; return 0; fi
    [ -f "$ENV_FILE" ] || return 0
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$ENV_FILE" | tail -n 1 || true)"
    [ -n "$line" ] || return 0
    value="${line#*=}"
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

# ── 包一层 compose 命令，自动带 --env-file（有 .env 时）─────────────────────
compose_cmd() {
    if [ -f "$ENV_FILE" ]; then
        docker compose --env-file "$ENV_FILE" -p deer-flow -f "$DOCKER_DIR/docker-compose.yaml" "$@"
    else
        docker compose -p deer-flow -f "$DOCKER_DIR/docker-compose.yaml" "$@"
    fi
}

# ── 前置检查：config.yaml / extensions_config.json / frontend/.env ──────────
prepare_configs() {
    if [ ! -f "$REPO_ROOT/config.yaml" ]; then
        if [ -f "$REPO_ROOT/config.example.yaml" ]; then
            cp "$REPO_ROOT/config.example.yaml" "$REPO_ROOT/config.yaml"
            run_in_repo "⚠ config.yaml 不存在，已从 config.example.yaml 复制。请编辑并设置模型 API Key。"
        else
            echo -e "${RED}✗ 未找到 config.yaml，且无 config.example.yaml 可复制。${NC}"
            echo "  请先执行：cp deploy-cn/config.local.yaml config.yaml"
            exit 1
        fi
    else
        run_in_repo "✓ config.yaml 存在"
    fi

    if [ ! -f "$REPO_ROOT/extensions_config.json" ]; then
        if [ -f "$REPO_ROOT/extensions_config.example.json" ]; then
            cp "$REPO_ROOT/extensions_config.example.json" "$REPO_ROOT/extensions_config.json"
            run_in_repo "✓ 已复制 extensions_config.example.json → extensions_config.json"
        else
            echo '{"mcpServers":{},"skills":{}}' > "$REPO_ROOT/extensions_config.json"
            run_in_repo "✓ 已生成空 extensions_config.json"
        fi
    fi

    # 前端生产容器通过 env_file: ../frontend/.env 读取 SSR 导向变量。
    # 该文件不存在会让 compose 启动 frontend 直接失败，这里兜底创建。
    if [ ! -f "$REPO_ROOT/frontend/.env" ]; then
        if [ -f "$REPO_ROOT/frontend/.env.example" ]; then
            cp "$REPO_ROOT/frontend/.env.example" "$REPO_ROOT/frontend/.env"
            run_in_repo "✓ 已复制 frontend/.env.example → frontend/.env"
        else
            : > "$REPO_ROOT/frontend/.env"
            run_in_repo "✓ 已生成空 frontend/.env"
        fi
    fi
}

# ── 默认 DEER_FLOW_HOME / 配置路径（与官方 deploy.sh 一致）────────────────────
export DEER_FLOW_HOME="${DEER_FLOW_HOME:-$REPO_ROOT/backend/.deer-flow}"
mkdir -p "$DEER_FLOW_HOME"
export DEER_FLOW_REPO_ROOT="$REPO_ROOT"
export DEER_FLOW_CONFIG_PATH="${DEER_FLOW_CONFIG_PATH:-$REPO_ROOT/config.yaml}"
export DEER_FLOW_EXTENSIONS_CONFIG_PATH="${DEER_FLOW_EXTENSIONS_CONFIG_PATH:-$REPO_ROOT/extensions_config.json}"

# ── 沙箱模式检测（复用官方逻辑）──────────────────────────────────────────────
detect_sandbox_mode() {
    [ -f "$DEER_FLOW_CONFIG_PATH" ] || { echo "local"; return; }
    local sandbox_use provisioner_url
    sandbox_use=$(awk '
        /^[[:space:]]*sandbox:[[:space:]]*$/ { in_sandbox=1; next }
        in_sandbox && /^[^[:space:]#]/ { in_sandbox=0 }
        in_sandbox && /^[[:space:]]*use:[[:space:]]*/ {
            line=$0; sub(/^[[:space:]]*use:[[:space:]]*/, "", line); print line; exit
        }
    ' "$DEER_FLOW_CONFIG_PATH")
    provisioner_url=$(awk '
        /^[[:space:]]*sandbox:[[:space:]]*$/ { in_sandbox=1; next }
        in_sandbox && /^[^[:space:]#]/ { in_sandbox=0 }
        in_sandbox && /^[[:space:]]*provisioner_url:[[:space:]]*/ {
            line=$0; sub(/^[[:space:]]*provisioner_url:[[:space:]]*/, "", line); print line; exit
        }
    ' "$DEER_FLOW_CONFIG_PATH")
    if [[ "$sandbox_use" == *"AioSandboxProvider"* ]]; then
        if [ -n "$provisioner_url" ]; then
            echo "provisioner"
        else
            echo "aio"
        fi
    else
        echo "local"
    fi
}

# ── 生成 BETTER_AUTH_SECRET / DEER_FLOW_INTERNAL_AUTH_TOKEN（持久化）─────────
ensure_secrets() {
    local _file="$DEER_FLOW_HOME/.better-auth-secret"
    if [ -z "${BETTER_AUTH_SECRET:-}" ]; then
        if [ -f "$_file" ]; then
            export BETTER_AUTH_SECRET="$(cat "$_file")"
            run_in_repo "✓ BETTER_AUTH_SECRET 从 $_file 加载"
        else
            export BETTER_AUTH_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            echo "$BETTER_AUTH_SECRET" > "$_file"
            chmod 600 "$_file"
            run_in_repo "✓ 已生成 BETTER_AUTH_SECRET"
        fi
    fi

    _file="$DEER_FLOW_HOME/.internal-auth-token"
    if [ -z "${DEER_FLOW_INTERNAL_AUTH_TOKEN:-}" ]; then
        if [ -f "$_file" ]; then
            export DEER_FLOW_INTERNAL_AUTH_TOKEN="$(cat "$_file")"
            run_in_repo "✓ DEER_FLOW_INTERNAL_AUTH_TOKEN 从 $_file 加载"
        else
            export DEER_FLOW_INTERNAL_AUTH_TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            echo "$DEER_FLOW_INTERNAL_AUTH_TOKEN" > "$_file"
            chmod 600 "$_file"
            run_in_repo "✓ 已生成 DEER_FLOW_INTERNAL_AUTH_TOKEN"
        fi
    fi
}

# ── 报告启动失败 ──────────────────────────────────────────────────────────────
report_startup_failure() {
    echo -e "${RED}✗ DeerFlow 服务未能就绪。${NC}" >&2
    echo -e "${YELLOW}  若提示 unknown flag: --wait，请升级 Docker Compose（docker-compose-plugin）。${NC}" >&2
    echo "  容器状态：" >&2
    compose_cmd ps >&2 || true
    echo "" >&2
    echo "  最近 Gateway 日志：" >&2
    compose_cmd logs --no-color --tail 100 gateway >&2 || true
}

# ── 校验 docker / compose 可用 ───────────────────────────────────────────────
require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}✗ 未找到 docker，请先安装 Docker。${NC}"; exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}✗ 未找到 docker compose v2（docker compose 子命令）。${NC}"
        echo "  请安装 compose plugin：sudo apt-get install -y docker-compose-plugin"
        exit 1
    fi
}

# ── 主流程 ───────────────────────────────────────────────────────────────────
CMD="${1:-}"

case "$CMD" in
    build|start|down|logs) ;;
    "") ;;
    *)
        echo "未知参数: $1"
        echo "用法: ./deploy.sh [build|start|down|logs [svc]]"
        exit 1
        ;;
esac

require_docker
prepare_configs
ensure_secrets

sandbox_mode="$(detect_sandbox_mode)"
run_in_repo "沙箱模式: ${sandbox_mode}"

services="redis frontend gateway nginx"
if [ "$sandbox_mode" = "provisioner" ]; then
    services="$services provisioner"
fi

# ── down ────────────────────────────────────────────────────────────────────
if [ "$CMD" = "down" ]; then
    export DEER_FLOW_HOME="${DEER_FLOW_HOME:-$REPO_ROOT/backend/.deer-flow}"
    export DEER_FLOW_CONFIG_PATH="${DEER_FLOW_CONFIG_PATH:-$DEER_FLOW_HOME/config.yaml}"
    export DEER_FLOW_EXTENSIONS_CONFIG_PATH="${DEER_FLOW_EXTENSIONS_CONFIG_PATH:-$DEER_FLOW_HOME/extensions_config.json}"
    export DEER_FLOW_REPO_ROOT="${DEER_FLOW_REPO_ROOT:-$REPO_ROOT}"
    export BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-placeholder}"
    export DEER_FLOW_INTERNAL_AUTH_TOKEN="${DEER_FLOW_INTERNAL_AUTH_TOKEN:-placeholder}"
    compose_cmd down
    exit 0
fi

# ── build ────────────────────────────────────────────────────────────────────
if [ "$CMD" = "build" ]; then
    echo "========================================"
    echo "  DeerFlow — 构建镜像"
    echo "========================================"
    MODE_APT="$(read_env APT_MIRROR)"
    MODE_UV_INDEX="$(read_env UV_INDEX_URL)"
    MODE_NPM="$(read_env NPM_REGISTRY)"
    MODE_UV_IMAGE="$(read_env UV_IMAGE)"
    MODE_UV_EXTRAS="$(read_env UV_EXTRAS)"
    MODE_LARK="$(read_env LARK_CLI_NPM_VERSION)"

    if [ -n "$MODE_APT" ]; then echo "  APT_MIRROR      = $MODE_APT"; fi
    if [ -n "$MODE_UV_INDEX" ]; then echo "  UV_INDEX_URL    = $MODE_UV_INDEX"; fi
    if [ -n "$MODE_NPM" ]; then echo "  NPM_REGISTRY    = $MODE_NPM"; fi
    if [ -n "$MODE_UV_IMAGE" ]; then echo "  UV_IMAGE        = $MODE_UV_IMAGE"; fi
    if [ -n "$MODE_UV_EXTRAS" ]; then echo "  UV_EXTRAS       = $MODE_UV_EXTRAS"; fi
    if [ -n "$MODE_LARK" ]; then echo "  LARK_CLI_NPM_VERSION = $MODE_LARK"; fi

    compose_cmd build
    echo ""
    echo "========================================"
    echo "  ✓ 镜像构建完成"
    echo "  下一步: ./deploy.sh start"
    echo "========================================"
    exit 0
fi

# ── logs ────────────────────────────────────────────────────────────────────
if [ "$CMD" = "logs" ]; then
    if [ -n "${2:-}" ]; then
        compose_cmd logs -f --tail 200 "$2"
    else
        compose_cmd logs -f --tail 200
    fi
    exit 0
fi

# ── start / up：先打印配置摘要，再启动 ──────────────────────────────────────
echo "========================================"
echo "  DeerFlow 生产部署"
echo "========================================"
echo ""
echo "  config.yaml  : $DEER_FLOW_CONFIG_PATH"
echo "  DEER_FLOW_HOME: $DEER_FLOW_HOME"
echo "  沙箱模式     : $sandbox_mode"

# DooD：仅 aio 模式才挂载宿主机 Docker socket（本地沙箱不需要）
if [ "$sandbox_mode" = "aio" ]; then
    export DEER_FLOW_DOCKER_SOCKET="${DEER_FLOW_DOCKER_SOCKET:-/var/run/docker.sock}"
    if [ ! -S "$DEER_FLOW_DOCKER_SOCKET" ]; then
        echo -e "${RED}⚠ 未找到 Docker socket: $DEER_FLOW_DOCKER_SOCKET${NC}"
        echo "  AioSandboxProvider (DooD) 将无法工作。"
        echo "  若想先用本地沙箱跑通，请把 config.yaml 的 sandbox.use 改回 LocalSandboxProvider。"
        exit 1
    fi
    run_in_repo "DooD 模式：将挂载 $DEER_FLOW_DOCKER_SOCKET 到 gateway"
fi

# 组装 compose 命令（aio 模式追加 DooD overlay），并区分是否重新构建
run_compose_up() {
    local args=()
    if [ -f "$ENV_FILE" ]; then args+=(--env-file "$ENV_FILE"); fi

    local files=(-p deer-flow -f "$DOCKER_DIR/docker-compose.yaml")
    if [ "$sandbox_mode" = "aio" ]; then
        files+=(-f "$DOCKER_DIR/docker-compose.dood.yaml")
    fi

    if [ "$CMD" = "start" ]; then
        docker compose "${files[@]}" "${args[@]}" \
            up -d --remove-orphans --wait --wait-timeout 180 $services
    else
        docker compose "${files[@]}" "${args[@]}" \
            up --build -d --remove-orphans --wait --wait-timeout 180 $services
    fi
}

if [ "$CMD" = "start" ]; then
    echo "启动容器（不重新构建）..."
    echo ""
else
    echo "构建镜像并启动容器..."
    echo ""
fi

if ! run_compose_up; then
    report_startup_failure; exit 1
fi

# ── 结果 ────────────────────────────────────────────────────────────────────
RESOLVED_PORT="$(read_env PORT)"; RESOLVED_PORT="${RESOLVED_PORT:-2026}"
RESOLVED_BIND="$(read_env BIND_HOST)"; RESOLVED_BIND="${RESOLVED_BIND:-127.0.0.1}"

echo ""
echo "========================================"
echo "  DeerFlow 已启动！"
echo "========================================"
echo "  🌐 应用入口: http://localhost:${RESOLVED_PORT}"
echo "  📡 API:       http://localhost:${RESOLVED_PORT}/api/*"
echo ""
if [ "$RESOLVED_BIND" = "127.0.0.1" ] || [ "$RESOLVED_BIND" = "::1" ] || [ "$RESOLVED_BIND" = "localhost" ]; then
    echo "  🔒 绑定 ${RESOLVED_BIND}（仅本机）。要跨机访问请在 .env 设 BIND_HOST=0.0.0.0"
else
    echo "  ⚠️  绑定 ${RESOLVED_BIND}（全网可达）。请立即完成 admin 账号创建。"
fi
echo ""
echo "  管理:"
echo "    ./deploy-cn/deploy.sh down   — 停止并删除容器"
echo "    ./deploy-cn/deploy.sh logs   — 查看日志"
echo ""
