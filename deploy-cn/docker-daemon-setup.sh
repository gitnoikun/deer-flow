#!/usr/bin/env bash
#
# 一键配置 Docker daemon 国内镜像加速 / 代理
#
# 用法（在 Linux 服务器上，需要 sudo 或 root）：
#   ./docker-daemon-setup.sh                      # 写入门户镜像加速
#   ./docker-daemon-setup.sh --mirrors 指定json   # 使用自定义 mirror 列表
# 示例自定义 mirror：
#   ./docker-daemon-setup.sh --mirrors '["https://docker.m.daocloud.io","https://docker.nju.edu.cn"]'
#
# 说明：
#   - 修改 /etc/docker/daemon.json 的 registry-mirrors 字段（不影响已有其他字段）。
#   - 提示：registry-mirrors 只对 Docker Hub 上的镜像生效；ghcr.io 等不在其上，
#     需要额外用代理（下文的 --proxy 选项）或在 insecure-registries 里加 ghcr.io。
#   - 修改后重启 docker daemon。
#
# 注意：本脚本会改动系统级 docker 配置，请确认你有权限。不做任何自动回滚，
#       但会先备份原文件到 /etc/docker/daemon.json.bak.<时间戳>。

set -euo pipefail

MIRRORS='["https://docker.m.daocloud.io","https://dockerproxy.com","https://docker.nju.edu.cn"]'
PROXY_HTTP=""
PROXY_HTTPS=""
NO_PROXY_DEF="localhost,127.0.0.1,gateway,frontend,nginx,redis,provisioner"

usage() {
    echo "用法: $0 [--mirrors JSON] [--proxy-http URL] [--proxy-https URL] [--no-proxy LIST]"
    echo ""
    echo "示例:"
    echo "  $0                                                  # 仅写入门户镜像加速"
    echo "  $0 --mirrors '[\"https://docker.nju.edu.cn\"]'        # 自定义镜像加速"
    echo "  $0 --proxy-http http://1.2.3.4:7890 --proxy-https http://1.2.3.4:7890   # 配代理"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mirrors)
            MIRRORS="$2"; shift 2 ;;
        --proxy-http)
            PROXY_HTTP="$2"; shift 2 ;;
        --proxy-https)
            PROXY_HTTPS="$2"; shift 2 ;;
        --no-proxy)
            NO_PROXY_DEF="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "未知参数: $1"; usage ;;
    esac
done

DOCKER_CONF="/etc/docker/daemon.json"

if [ ! -d /etc/docker ]; then
    echo "⚠ /etc/docker 目录不存在，正在创建..."
    sudo mkdir -p /etc/docker
fi

# ── 备份 ─────────────────────────────────────────────────────────────────────
if [ -f "$DOCKER_CONF" ]; then
    TS="$(date +%Y%m%d%H%M%S)"
    sudo cp "$DOCKER_CONF" "${DOCKER_CONF}.bak.${TS}"
    echo "✓ 已备份原配置到 ${DOCKER_CONF}.bak.${TS}"
fi

# ── 读取现有 JSON（保留其它字段）──────────────────────────────────────────────
CURRENT="{}"
if [ -f "$DOCKER_CONF" ]; then
    CURRENT="$(sudo cat "$DOCKER_CONF")"
fi

# ── 用 python 安全合并（JSON 合法性）─────────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
    sudo python3 - "$DOCKER_CONF" "$CURRENT" "$MIRRORS" "$PROXY_HTTP" "$PROXY_HTTPS" "$NO_PROXY_DEF" <<'PY'
import json, sys

conf_path, current, mirrors, proxy_http, proxy_https, no_proxy = sys.argv[1:7]

try:
    conf = json.loads(current) if current.strip() else {}
except json.JSONDecodeError:
    conf = {}

conf["registry-mirrors"] = json.loads(mirrors)

if proxy_http or proxy_https:
    conf.setdefault("proxies", {})
    if proxy_http:
        conf["proxies"]["http-proxy"] = proxy_http
    if proxy_https:
        conf["proxies"]["https-proxy"] = proxy_https
    conf["proxies"]["no-proxy"] = no_proxy

with open(conf_path, "w") as f:
    json.dump(conf, f, indent=2)
    f.write("\n")
PY
else
    echo "✗ 需要 python3 来安全地合并 JSON。"
    exit 1
fi

# ── 重启 docker daemon ──────────────────────────────────────────────────────
echo "正在重启 docker daemon..."
if sudo command -v systemctl >/dev/null 2>&1; then
    sudo systemctl restart docker
elif sudo command -v service >/dev/null 2>&1; then
    sudo service docker restart
else
    echo "⚠ 无法自动重启 docker，请手动重启。"
fi

echo ""
echo "=========================================="
echo "  已写入 docker 配置并重启"
echo "=========================================="
echo "  registry-mirrors: $(echo "$MIRRORS" | tr -d '[:space:]')"
[ -n "$PROXY_HTTP" ] && echo "  http-proxy:  $PROXY_HTTP"
[ -n "$PROXY_HTTPS" ] && echo "  https-proxy: $PROXY_HTTPS"
echo ""
echo "  验证拉取：docker pull hello-world"
echo "  验证 ghcr：docker pull ghcr.io/astral-sh/uv:0.11.1"
echo ""
echo "  提示：registry-mirrors 只对 Docker Hub 生效。ghcr.io / nodesource"
echo "  这类不在 Docker Hub 上的下载，需靠 —proxy 代理或网络本身能达。"
