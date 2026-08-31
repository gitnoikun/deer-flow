#!/usr/bin/env bash
# 一键配置服务器代理到 Windows Clash(192.168.77.10:7897)
# 1. Docker daemon 代理（拉镜像走代理）
# 2. 全局 shell 代理（供 build/容器内使用）
# 3. 重启 Docker 生效
set -euo pipefail
PROXY_HOST="192.168.77.10"
PROXY_PORT="7897"
PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
PROXY_NO_PROXY="localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.aliyun.com,registry.npmmirror.com"

echo "==== 1. 配置 Docker daemon 代理 ===="
# 用 python 安全合并 daemon.json，避免破坏已有 registry-mirrors 等配置
python3 - <<'PYEOF'
import json, sys
daemon_path = "/etc/docker/daemon.json"
try:
    with open(daemon_path, "r") as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
except json.JSONDecodeError:
    cfg = {}

cfg["proxies"] = {
    "http-proxy": "http://192.168.77.10:7897",
    "https-proxy": "http://192.168.77.10:7897",
    "no-proxy": "localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.aliyun.com,registry.npmmirror.com"
}
with open(daemon_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("已写入 daemon.json proxies 段")
PYEOF

# 若 python3 不存在则退回到直接写文件
if ! python3 -c 'import json' >/dev/null 2>&1; then
  cat > /tmp/daemon.json.patch <<'EOF'
{"proxies":{"http-proxy":"http://192.168.77.10:7897","https-proxy":"http://192.168.77.10:7897","no-proxy":"localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.aliyun.com,registry.npmmirror.com"}}
EOF
  echo "python3 不可用，请手动合并 daemon.json: 见 /tmp/daemon.json.patch"
fi

echo ""
echo "==== 2. 配置 shell 全局代理 ===="
cat > /etc/profile.d/deerflow-proxy.sh <<EOF
export http_proxy="$PROXY"
export https_proxy="$PROXY"
export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export no_proxy="$PROXY_NO_PROXY"
export NO_PROXY="$PROXY_NO_PROXY"
EOF
echo "已写入 /etc/profile.d/deerflow-proxy.sh"

echo ""
echo "==== 3. 重启 Docker ===="
systemctl daemon-reload
systemctl restart docker
sleep 5

echo ""
echo "==== 4. 验证 ===="
systemctl is-active docker && echo "Docker 已运行" || echo "Docker 状态异常!"
echo "--- 当前 daemon.json ---"
cat /etc/docker/daemon.json
echo ""
echo "--- 用代理拉一个测试镜像 ---"
docker pull hello-world:latest >/dev/null 2>&1 && echo "代理拉取 hello-world 成功 ✓" || echo "代理拉取 hello-world 失败 ✗ (需检查 clash allow-lan)"
echo "PROXY_SETUP_DONE"
