# 图片处理工具（公网版 · Cloudflare Tunnel）

手机端图片上传 → 左右翻转 → 返回结果。支持公网 HTTPS 访问，多层安全防护。

> **无需公网 IP、无需端口转发、无需域名。**

## 🔒 安全特性

| 层级 | 措施 |
|------|------|
| 传输 | HTTPS（Cloudflare 自动提供） |
| 访问控制 | IP 白名单 + 速率限制 (10次/分钟) |
| 图片校验 | 魔数检测、解压炸弹防护、尺寸限制 |
| 并发控制 | 全局锁，单请求串行处理 |
| 隐私 | EXIF 元数据自动剥离 |
| 容器化 | Docker 隔离 |

## 项目结构

```
├── backend/
│   ├── app.py              # Flask 应用（安全加固）
│   ├── config.json         # 白名单 & 限制配置
│   └── requirements.txt
├── frontend/
│   └── index.html          # 移动端页面（自动重试）
├── nginx/                  # 已废弃（Cloudflare 替代）
├── scripts/                # 已废弃
├── Dockerfile
├── docker-compose.yml      # app + cloudflared
└── README.md
```

## 架构

```
手机 (任意网络)
    │
    ▼
Cloudflare 边缘节点（免费 HTTPS）
    │
    ▼
cloudflared 隧道（从电脑主动连出）
    │
    ▼
chekinana-app（Flask + Waitress）
```

## 快速开始

### 前置条件

- **Docker Desktop** 已安装并运行
- 配置了 Docker 镜像加速（国内必需）

### 第 1 步：配置白名单

编辑 `backend/config.json`，添加允许访问的 IP：

```json
{
    "allowed_ips": [
        "你的公网IP",
        "手机运营商IP/24"
    ],
    ...
}
```

### 第 2 步：启动服务

```powershell
docker-compose up -d
```

### 第 3 步：获取公网地址

```powershell
docker logs chekinana-tunnel 2>&1 | Select-String "trycloudflare.com"
```

输出示例：

```
https://open-spice-adventures-decimal.trycloudflare.com
```

手机浏览器打开这个地址即可使用。

## 日常管理

| 操作 | 命令 |
|------|------|
| 修改白名单 | 编辑 `config.json` → `docker-compose restart app` |
| 查看日志 | `docker-compose logs -f app` |
| 获取当前地址 | `docker logs chekinana-tunnel \| findstr trycloudflare` |
| 停止服务 | `docker-compose down` |
| 重启服务 | `docker-compose up -d` |

## 配置说明 (`backend/config.json`)

| 字段 | 说明 |
|------|------|
| `allowed_ips` | IP 白名单，支持 CIDR 格式（如 `192.168.0.0/16`） |
| `max_image_mb` | 上传图片最大体积 |
| `max_dimensions` | 图片最大宽/高 |
| `rate_limit_per_minute` | 每 IP 每分钟最大请求数 |
| `request_timeout_seconds` | 排队超时时间 |

## 常见问题

**Q: 重启后 URL 变了？**
A: 免费隧道每次重启会分配新地址，执行 `docker logs chekinana-tunnel | findstr trycloudflare` 获取新地址。

**Q: 如何获得固定地址？**
A: 注册 Cloudflare 账号 + 绑定自己的域名，使用命名隧道即可固定。

**Q: 外网无法访问？**
A: 检查 `allowed_ips` 是否包含访问者的公网 IP。查看被拦截日志：`docker logs chekinana-app | findstr BLOCKED`。
