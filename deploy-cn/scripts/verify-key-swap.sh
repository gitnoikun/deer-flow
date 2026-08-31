#!/usr/bin/env bash
BASE="/opt/code/deer-flow"
ENV_FILE="$BASE/.env"
echo "=== 服务器生效 .env 的 DEEPSEEK_API_KEY 状态(脱敏) ==="
CUR=$(grep -oP '^DEEPSEEK_API_KEY=\K.*' "$ENV_FILE" 2>/dev/null || echo "")
if [ -z "$CUR" ]; then
  echo "  服务器 $ENV_FILE 里未找到 DEEPSEEK_API_KEY"
else
  echo "  当前 key 前缀: ${CUR:0:6}... 长度: ${#CUR}"
  if [ "${CUR:0:6}" = "sk-4b73" ]; then
    echo "  判定: 仍是旧 key(sk-4b73...), 说明服务器 .env 还没被替换"
  else
    echo "  判定: 已变成新 key(前缀 != sk-4b73), 服务器 .env 已更新"
  fi
fi
echo ""
echo "=== 本地模板 .env.server(若也在,只展示是否变化) ==="
if [ -f "$BASE/.env.server" ]; then
  L=$(grep -oP '^DEEPSEEK_API_KEY=\K.*' "$BASE/.env.server" 2>/dev/null || echo "")
  echo "  本地 .env.server 前缀: ${L:0:6}... (长度${#L})" 2>/dev/null || echo "  未找到"
fi
echo ""
echo "=== config.yaml 引用仍为 \$DEEPSEEK_API_KEY(无需改) ==="
grep -n "api_key:" "$BASE/config.yaml" | head
echo ""
echo "=== 若有备份,列出(确认是否有安全网) ==="
ls -1 "$BASE"/.env.bak.* 2>/dev/null | tail -3 || echo "  无备份文件"
echo "VERIFY_KEY_DONE"
