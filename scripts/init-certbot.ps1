# ============================================================
# 首次证书签发脚本（Windows PowerShell 版）
# 用法: .\scripts\init-certbot.ps1 -PublicIP "123.45.67.89"
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$PublicIP
)

$ErrorActionPreference = "Stop"
$DOMAIN = "${PublicIP}.nip.io"
$EMAIL = "admin@${DOMAIN}"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  🔐 Let's Encrypt 证书初始化"
Write-Host "  域名: ${DOMAIN}"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. 启动服务
Write-Host "📦 步骤 1/4: 构建并启动服务（HTTP 模式）..." -ForegroundColor Yellow
docker-compose up -d --build
Write-Host "⏳ 等待服务就绪..."
Start-Sleep -Seconds 8

# 2. 验证可达性
Write-Host ""
Write-Host "🌐 步骤 2/4: 验证服务可达..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://${DOMAIN}/api/health" -TimeoutSec 10 -UseBasicParsing
    Write-Host "✅ 服务可达 (HTTP $($response.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host "⚠️  警告: 无法通过 ${DOMAIN} 访问服务" -ForegroundColor Red
    Write-Host ""
    Write-Host "   请确认："
    Write-Host "   1. 公网 IP 正确: ${PublicIP} (可通过浏览器访问 https://ip.sb 确认)"
    Write-Host "   2. 路由器端口转发: 80→本机80, 443→本机443"
    Write-Host "   3. 本机防火墙已放行 80/443 端口"
    Write-Host ""
    $continue = Read-Host "是否继续尝试获取证书？(y/N)"
    if ($continue -ne "y" -and $continue -ne "Y") {
        Write-Host "已取消。"
        exit 1
    }
}

# 3. 获取证书
Write-Host ""
Write-Host "📜 步骤 3/4: 申请 Let's Encrypt 证书..." -ForegroundColor Yellow
docker-compose run --rm certbot `
    certonly `
    --webroot `
    --webroot-path=/var/www/certbot `
    --email "${EMAIL}" `
    --agree-tos `
    --no-eff-email `
    --force-renewal `
    -d "${DOMAIN}"

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "❌ 证书申请失败！" -ForegroundColor Red
    exit 1
}

# 4. 切换到 HTTPS
Write-Host ""
Write-Host "🔒 步骤 4/4: 启用 HTTPS..." -ForegroundColor Yellow
$template = Get-Content "nginx/nginx-https.template" -Raw
$template = $template.Replace('${DOMAIN}', $DOMAIN)
Set-Content "nginx/nginx.conf" $template

Write-Host "🔄 重启 Nginx..."
docker-compose restart nginx
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ✅ 全部完成！" -ForegroundColor Green
Write-Host ""
Write-Host "  🔒 HTTPS: https://${DOMAIN}"
Write-Host "  📋 白名单: backend/config.json"
Write-Host "  📅 证书自动续期: 每 12h 检查"
Write-Host ""
Write-Host "  修改白名单后: docker-compose restart app"
Write-Host "========================================" -ForegroundColor Cyan
