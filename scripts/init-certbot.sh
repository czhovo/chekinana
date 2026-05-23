#!/bin/bash
# ============================================================
# 首次证书签发脚本（适用于 Windows Git Bash / WSL / Linux）
# 用法: bash scripts/init-certbot.sh <你的公网IP>
# 示例: bash scripts/init-certbot.sh 123.45.67.89
# ============================================================

set -e

if [ -z "$1" ]; then
    echo "❌ 请提供你的公网 IP 地址"
    echo "用法: bash $0 <公网IP>"
    echo "示例: bash $0 123.45.67.89"
    exit 1
fi

PUBLIC_IP="$1"
DOMAIN="${PUBLIC_IP}.nip.io"
EMAIL="admin@${DOMAIN}"

echo ""
echo "========================================"
echo "  🔐 Let's Encrypt 证书初始化"
echo "  域名: ${DOMAIN}"
echo "========================================"
echo ""

# 1. 启动服务（HTTP 模式）
echo "📦 步骤 1/4: 构建并启动服务（HTTP 模式）..."
docker-compose up -d --build
echo "⏳ 等待服务就绪..."
sleep 8

# 2. 验证可达性
echo ""
echo "🌐 步骤 2/4: 验证服务可达..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN}/api/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "200" ]; then
    echo "⚠️  警告: 无法通过 ${DOMAIN} 访问服务 (HTTP ${HTTP_CODE})"
    echo ""
    echo "   请确认："
    echo "   1. 公网 IP 正确: ${PUBLIC_IP} (可通过 https://ip.sb 确认)"
    echo "   2. 路由器端口转发: 80→本机80, 443→本机443"
    echo "   3. 本机防火墙已放行 80/443 端口"
    echo ""
    read -r -p "是否继续尝试获取证书？(y/N) " REPLY
    if [ "${REPLY}" != "y" ] && [ "${REPLY}" != "Y" ]; then
        echo "已取消。"
        exit 1
    fi
else
    echo "✅ 服务可达"
fi

# 3. 获取证书
echo ""
echo "📜 步骤 3/4: 申请 Let's Encrypt 证书..."
docker-compose run --rm certbot \
    certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --force-renewal \
    -d "${DOMAIN}"

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ 证书申请失败！"
    exit 1
fi

# 4. 切换到 HTTPS
echo ""
echo "🔒 步骤 4/4: 启用 HTTPS..."
sed "s/\${DOMAIN}/${DOMAIN}/g" nginx/nginx-https.template > nginx/nginx.conf
echo "🔄 重启 Nginx..."
docker-compose restart nginx
sleep 3

echo ""
echo "========================================"
echo "  ✅ 全部完成！"
echo ""
echo "  🔒 HTTPS: https://${DOMAIN}"
echo "  📋 白名单: backend/config.json"
echo "  📅 证书自动续期: 每 12h 检查"
echo ""
echo "  修改白名单后: docker-compose restart app"
echo "========================================"
