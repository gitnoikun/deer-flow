# ============================================================================
# Windows 侧提交辅助脚本
# 用法：powershell -ExecutionPolicy Bypass -File .\git-push.ps1
#   - 自动 checkout dev 分支
#   - 一键 add + commit + push
#   - 提交信息可自定义（默认按日期）
# ============================================================================

param(
    [string]$Message = "update: deploy-cn prep ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
)

$ErrorActionPreference = "Stop"

# 切到仓库根目录（本脚本所在目录的上级）
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

Write-Host "当前分支: $(git branch --show-current)"

# 确保在 dev 分支
if ((git branch --show-current) -ne "dev") {
    Write-Host "切换到 dev 分支..."
    git checkout dev
}

Write-Host "待提交文件:"
git status --short

Write-Host ""
git add -A

Write-Host "提交: $Message"
git commit -m $Message

Write-Host "推送..."
git push origin dev

Write-Host ""
Write-Host "✅ 完成。Linux 服务器上执行: git pull && ./deploy-cn/deploy.sh"
