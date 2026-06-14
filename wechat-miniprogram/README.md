# chekinana 微信小程序前端

这是用于从图片中提取拍立得的微信小程序前端。

## 功能

1. 选择或拍摄一张包含拍立得的图片。
2. 通过后端接口提取图片中的拍立得。
3. 支持白平衡开关。
4. 在页面下半部分以两列网格展示提取结果。
5. 点击任意结果图片可保存到相册。
6. 状态栏显示待处理、处理中、处理结束和提取数量。

## 接口配置

在 `pages/index/index.js` 顶部配置后端地址：

```js
const API_BASE_URL = "https://your-domain.example.com";
```

前端会调用：

- `POST /api/process`
  - 上传字段名：`image`
  - 表单字段：`wb`，值为 `"1"` 或 `"0"`

接口可以直接返回结果：

```json
{
  "images": [
    "https://your-domain.example.com/results/a.png",
    "https://your-domain.example.com/results/b.png"
  ]
}
```

也可以返回异步任务：

```json
{
  "task_id": "abc123"
}
```

异步任务会轮询：

- `GET /api/status/<task_id>`

完成时返回 `images`、`results`、`outputs` 或 `files` 均可。

## 使用

1. 打开微信开发者工具。
2. 导入本目录：`wechat-miniprogram`。
3. 在 `pages/index/index.js` 配置 `API_BASE_URL`。
4. 编译后选择图片，点击“开始提取”。
