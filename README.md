# Chekinana

Chekinana 是一个微信小程序 + Flask 后端项目，用于从用户上传的照片中检测并提取拍立得照片。

## 当前功能

- 微信小程序端上传图片并查看提取结果。
- 支持一次选择多张图片，单次最多 9 张。
- 支持为每张图片填写可选的目标拍立得数量。
- 支持 `mini`、`wide`、`auto` 三种拍立得尺寸模式。
- 支持关闭后处理、降噪、锐化三种后处理模式。
- 支持白平衡、旋转、取消任务、保存提取结果到相册。
- 支持联系作者反馈。
- 支持连连看页面，图片素材和通关音频从 `chekinana.top` 下载并缓存。

## 项目结构

```text
backend/                Flask API 与图像提取逻辑
cloudflare-pages/       chekinana.top 静态资源源
cloudflare-worker/      RunPod API 代理 Worker
docs/agents/            多 agent 协作任务板和交接文档
nginx/                  可选反向代理配置
scripts/                辅助脚本与校验脚本
wechat-miniprogram/     微信小程序前端
Dockerfile
docker-compose.yml
```

## 微信小程序

小程序代码位于 `wechat-miniprogram/`。

主要流程：

1. 用户输入访问 token。
2. 选择或拍摄最多 9 张图片。
3. 为每张图片选择拍立得尺寸模式，并可填写目标数量。
4. 上传图片到后端任务接口。
5. 前端轮询任务状态，并在后端返回每张拍立得后立即显示和缓存结果。
6. 用户可以单张保存或全部保存到系统相册。

后端地址配置位于：

```text
wechat-miniprogram/utils/config.js
```

## 后端

后端代码位于 `backend/`，核心入口为：

```text
backend/app.py
```

主要接口：

```text
GET  /api/health
POST /api/auth/verify
POST /api/process
GET  /api/status/<task_id>
GET  /api/result/<task_id>/<result_id>
POST /api/task/<task_id>/cancel
```

接口通过 `X-Cheki-Token` 校验访问 token。生产环境通过 RunPod 启动后端，并由 Cloudflare Worker 代理到对外 API 域名。

## 静态资源

`cloudflare-pages/` 是 `chekinana.top` 的 Cloudflare Pages 静态资源源。

当前包含：

- 连连看 14 张图片素材
- 连连看通关音频 `muguang.m4a`
- `assets/lianliankan/v1/manifest.json`

公开资源入口：

```text
https://chekinana.top/assets/lianliankan/v1/manifest.json
```

相关校验脚本：

```powershell
python scripts\check_lianliankan_assets.py
python scripts\check_lianliankan_public_assets.py
```

## 本地开发参考

后端本地启动：

```powershell
cd backend
python app.py
```

指定访问 token：

```powershell
$env:CHEKINANA_ACCESS_TOKEN="your_token"
python app.py
```

小程序端使用微信开发者工具打开 `wechat-miniprogram/`。
