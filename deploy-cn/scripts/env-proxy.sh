#!/usr/bin/env bash
# 确保代理环境变量对所有 shell（含非交互 ssh）生效
set -euo pipefail
PROXY="http://192.168.77.10:7897"
NO_PROXY="localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.aliyun.com,registry.npmmirror.com"

# 写入 /etc/environment（PAM 读取，对所有进程含非交互 ssh 生效）
grep -q "http_proxy" /etc/environment 2>/dev/null && sed -i '/http_proxy/d;/https_proxy/d;/HTTP_PROXY/d;/HTTPS_PROXY/d;/no_proxy/d;/NO_PROXY/d' /etc/environment || true
cat >> /etc/environment <<EOF
http_proxy=$PROXY
https_proxy=$PROXY
HTTP_PROXY=$PROXY
HTTPS_PROXY=$PROXY
no_proxy=$NO_PROXY
NO_PROXY=$NO_PROXY
EOF
echo "已更新 /etc/environment："
cat /etc/environment

echo ""
echo "---- 验证：新登录 shell 是否带上代理 ----"
# 用 bash -lc 模拟登录 shell
bash -lc 'echo "http_proxy=$http_proxy"; echo "https_proxy=$https_proxy"'

echo ""
echo "---- 验证：通过代理访问外网 ----"
curl -s -o /dev/null -w "pypi.org via env proxy: HTTP %{http_code}\n" --connect-timeout 8 --max-time 20 https://pypi.org/simple/ || echo "代理访问失败"
curl -s -o /dev/null -w "ghcr.io  via env proxy: HTTP %{http_code}\n" --connect-timeout 8 --max-time 20 https://ghcr.io/v2/ || echo "代理访问 ghcr 失败"
echo "ENV_PROXY_DONE"
