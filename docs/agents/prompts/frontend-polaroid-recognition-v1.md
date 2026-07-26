# 拍立得识别接口

## 1. 创建任务

```http
POST /api/process
Content-Type: multipart/form-data
X-Cheki-Token: <token>
```

multipart 字段：

```text
image=<输入图片的 JPEG 二进制>
ink=0|1
```

- `ink=0`：不生成墨迹图片。
- `ink=1`：为每张识别出的拍立得生成墨迹图片。

接口成功时返回：

```json
{
  "task_id": "<完整任务 ID>",
  "status": "queued"
}
```

## 2. 查询任务

```http
GET /api/status/<task_id>
X-Cheki-Token: <token>
```

处理中：

```json
{
  "status": "processing"
}
```

完成时：

```json
{
  "status": "done",
  "results": [
    {
      "id": 0,
      "polaroid_result_id": 0,
      "ink_result_id": 1,
      "date": "2026.06.06",
      "bbox": [57, 0, 1002, 182],
      "pattern": "pattern1"
    }
  ]
}
```

结果字段：

- `id`：该识别结果的序号。
- `polaroid_result_id`：拍立得图片的下载 ID。
- `ink_result_id`：墨迹图片的下载 ID；请求 `ink=0` 时为 `null`。
- `date`：识别出的日期；无法识别时为 `null`。
- `bbox`：日期在拍立得图片中的像素坐标 `[x1, y1, x2, y2]`；无法识别日期时为 `null`。
- `pattern`：人物匹配结果；只可能是 `pattern1`–`pattern6` 或
  `"unassigned"`。Backend 不得让其他 gallery 类别参与分类。
- `date` 和 `bbox` 必须同时有值或同时为 `null`。

`pattern` 与人物名称的固定对应：

| pattern | name |
| --- | --- |
| `pattern1` | `aina` |
| `pattern2` | `eriko` |
| `pattern3` | `巫歌` |
| `pattern4` | `木兰` |
| `pattern5` | `优子` |
| `pattern6` | `饭饭` |
| `unassigned` | `未匹配人物` |

失败时：

```json
{
  "status": "failed",
  "error": "<固定错误码>"
}
```

## 3. 下载结果图片

下载拍立得图片：

```http
GET /api/result/<task_id>/<polaroid_result_id>
X-Cheki-Token: <token>
```

下载墨迹图片：

```http
GET /api/result/<task_id>/<ink_result_id>
X-Cheki-Token: <token>
```

两个下载接口都直接返回图片二进制。

不再使用 `date_annotation=1`。日期、日期框和人物匹配结果统一从任务状态响应中取得。
