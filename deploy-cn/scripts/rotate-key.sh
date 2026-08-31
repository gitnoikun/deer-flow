#!/usr/bin/env bash
# 安全替换服务器 .env 里的 DEEPSEEK_API_KEY
# 用法: bash rotate-key.sh <新key>
set -uo pipefail
BASE="/opt/code/deer-flow"
ENV_FILE="$BASE/.env"
NEW_KEY="${1:-}"

if [ -z "$NEW_KEY" ]; then
  echo "用法: bash rotate-key.sh <新key>"
  exit 1
fi
if [ "$NEW_KEY" = "$(grep -oP '^DEEPSEEK_API_KEY=\K.*' "$ENV_FILE" 2>/dev/null)" ]; then
  echo "新 key 与当前相同，无需修改"
  exit 0
fi

echo "=== 备份旧 .env 到 .env.bak.$(date +%s) ==="
cp -a "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
echo "备份完成"
echo ""
echo "=== 替换 DEEPSEEK_API_KEY ==="
# 先确认旧 key(脱敏)
OLD=$(grep -oP '^DEEPSEEK_API_KEY=\K.*' "$ENV_FILE" || true)
if [ -n "$OLD" ]; then
  echo "旧 key 前缀: ${OLD:0:6}... 长度${#OLD}"
fi
# 原子替换
sed -i "s|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=$NEW_KEY|" "$ENV_FILE"
echo ""
echo "=== 校验新 key 已写入(脱敏) ==="
NEW=$(grep -oP '^DEEPSEEK_API_KEY=\K.*' "$ENV_FILE" || true)
echo "新 key 前缀: ${NEW:0:6}... 长度${#NEW}"
echo ""
echo "=== 确认 config.yaml 仍引用 \$DEEPSEEK_API_KEY(无需改动) ==="
grep -n "api_key:" "$BASE/config.yaml" | head
echo "ROTATE_DONE"
