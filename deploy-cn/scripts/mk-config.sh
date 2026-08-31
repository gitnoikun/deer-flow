#!/usr/bin/env bash
# 创建 extensions_config.json 和 frontend/.env
cd /opt/code/deer-flow || exit 1

# extensions_config.json
if [ -f extensions_config.example.json ]; then
    cp extensions_config.example.json extensions_config.json
    echo "✓ extensions_config.json 从模板复制"
else
    echo '{"mcpServers":{},"skills":{}}' > extensions_config.json
    echo "✓ extensions_config.json 已生成空"
fi

# frontend/.env
if [ -f frontend/.env.example ]; then
    cp frontend/.env.example frontend/.env
    echo "✓ frontend/.env 从模板复制"
else
    : > frontend/.env
    echo "✓ frontend/.env 已生成空"
fi

echo "--- 当前配置核对 ---"
for f in .env config.yaml extensions_config.json frontend/.env; do
    [ -f "$f" ] && echo "存在: $f" || echo "缺失: $f"
done
echo "END"
