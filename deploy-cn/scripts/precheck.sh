#!/usr/bin/env bash
echo "=== 端口占用检查 ==="
for p in 2026 3000 8001 8002 6379; do
    if ss -tlnp 2>/dev/null | grep -q ":$p "; then
        owner=$(ss -tlnp 2>/dev/null | grep ":$p " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "-")
        echo "端口 $p : 已被占用 (进程: $owner)"
    else
        echo "端口 $p : 空闲"
    fi
done

echo ""
echo "=== /opt/code/deer-flow 现有配置文件 ==="
for f in .env config.yaml extensions_config.json frontend/.env; do
    if [ -f "/opt/code/deer-flow/$f" ]; then
        echo "存在: $f"
    else
        echo "缺失: $f"
    fi
done

echo ""
echo "=== deploy-cn 是否存在 ==="
if [ -d "/opt/code/deer-flow/deploy-cn" ]; then ls /opt/code/deer-flow/deploy-cn; else echo "deploy-cn 不存在"; fi

echo ""
echo "=== git 状态 ==="
cd /opt/code/deer-flow && git branch --show-current 2>/dev/null && git log --oneline -3 2>/dev/null

echo ""
echo "=== 内存/磁盘 ==="
free -h 2>/dev/null | head -2
df -h / 2>/dev/null | tail -1
echo "=== END ==="
