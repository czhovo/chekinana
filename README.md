# chekinana

微信小程序前端 + Flask API 后端，用于从照片中检测并提取拍立得。

## 项目结构

```text
├── backend/
│   ├── app.py              # Flask API 服务
│   ├── config.json         # 白名单、限流、图片限制
│   └── requirements.txt
├── wechat-miniprogram/     # 微信小程序前端
├── scripts/                # 部署辅助脚本
├── nginx/                  # 可选反向代理配置
├── Dockerfile
├── docker-compose.yml
└── README.md
```

## 小程序前端

小程序目录：`wechat-miniprogram`

主要流程：

1. 输入访问 Token。
2. 选择或拍摄一张包含拍立得的照片。
3. 上传到后端 `POST /api/process`。
4. 轮询 `GET /api/status/<task_id>`。
5. 展示 `/api/result/<task_id>/<result_id>` 返回的提取结果。
6. 点击结果图片保存到相册。

后端地址在 `wechat-miniprogram/utils/config.js` 中配置：

```js
const API_BASE_URL = "https://your-domain.example.com";
```

## 后端接口

启动后端：

```powershell
cd backend
python app.py
```

后端启动时会在日志中打印访问 Token：

```text
访问 Token (generated): ...
```

也可以用环境变量固定 Token，方便 RunPod 重启后继续使用同一个值：

```powershell
$env:CHEKINANA_ACCESS_TOKEN="your_token"
python app.py
```

健康检查：

```text
GET /api/health
```

验证 Token：

```text
POST /api/auth/verify
Header: X-Cheki-Token: <token>
```

提交图片：

```text
POST /api/process
Header: X-Cheki-Token: <token>
```

查询任务：

```text
GET /api/status/<task_id>
Header: X-Cheki-Token: <token>
```

获取结果图片：

```text
GET /api/result/<task_id>/<result_id>
Header: X-Cheki-Token: <token>
```
