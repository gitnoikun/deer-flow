#!/usr/bin/env bash
# 最终部署前检查：配置齐备性 + 代理生效
cd /opt/code/deer-flow || exit 1

echo "==== 1. 运行时配置文件 ===="
for f in .env config.yaml extensions_config.json frontend/.env; do
  if [ -f "$f" ]; then echo "  存在: $f ($(wc -c < "$f") bytes)"; else echo "  ✗ 缺失: $f"; fi
done

echo ""
echo "==== 2. .env 中代理与 DeepSeek ===="
echo "  HTTP_PROXY  => $(grep -E '^HTTP_PROXY=' .env | head -1 || echo '(未设置)')"
echo "  HTTPS_PROXY => $(grep -E '^HTTPS_PROXY=' .env | head -1 || echo '(未设置)')"
echo "  DEEPSEEK_KEY=> $(grep -cE '^DEEPSEEK_API_KEY=sk-' .env) (行数, 应为1)"

echo ""
echo "==== 3. config.yaml 模型与沙箱 ===="
echo "  patched_openai: $(grep -c 'patched_openai' config.yaml)"
echo "  LocalSandbox:   $(grep -c 'LocalSandboxProvider' config.yaml)"

echo ""
echo "==== 4. deploy.sh 可执行性 ===="
if [ -x deploy-cn/deploy.sh ]; then echo "  可执行: yes"; else echo "  ✗ 不可执行，需 chmod +x deploy-cn/deploy.sh"; fi

echo ""
echo "==== 5. Docker 代理生效 ===="
echo "  daemon proxies: $(grep -c '192.168.77.10:7897' /etc/docker/daemon.json) (应为1)"
echo "  /etc/environment http_proxy => $(grep -E '^http_proxy=' /etc/environment | head -1)"

echo ""
echo "==== 6. 端口占用（关键端口应空闲）===="
for p in 2026 8001 3000 6379; do
  if ss -tlnp 2>/dev/null | grep -q ":$p "; then echo "  ✗ 端口 $p 被占用"; else echo "  端口 $p 空闲"; fi
done

echo ""
echo "VERIFY_DONE"
