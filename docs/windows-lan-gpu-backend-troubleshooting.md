# Windows 本地 GPU 后端与 Wrangler 排障经验

本文记录在 Windows 上使用本地 Python/CUDA Scanner 和本地 Wrangler
替代生产 Scanner 链路时遇到的问题、确认根因的方法和已经验证的解决方案。
它是 [`windows-lan-gpu-backend.md`](./windows-lan-gpu-backend.md) 的排障补充，
不是另一套部署方案。

本文中的地址、凭据和任务标识均使用占位符。不要把本地 token、Qwen
密钥、私网地址或完整 task/result ID 写入日志、文档或 Git。

## 1. 先明确本地链路

本地测试替代了生产链路中的两个运行组件：

```text
前端或测试客户端
  -> http://<Windows 私网 IP>:8787
  -> 本地 Wrangler / workerd（运行当前 checkout 的 Worker）
  -> http://127.0.0.1:8080
  -> Windows Python / CUDA / SAM3（替代 RunPod）
```

边界必须保持不变：

- 前端只访问 Wrangler 的 `8787`，不直接访问 Python。
- Python 只监听 `127.0.0.1:8080`。
- Wrangler 可以监听局域网，但 Windows 防火墙只允许
  `Private` 配置文件中的 `LocalSubnet` 访问 `8787`。
- 本地 Scanner token 只允许通过 `X-Cheki-Token` 认证。
- Wrangler 转发前删除 token header、multipart 中的 `token` 字段和客户端
  伪造的 forwarding/IP headers。
- 本地上游必须是固定的 IPv4 loopback，不能由客户端指定。
- 未配置本地模式变量时，生产 RunPod 路径的行为不得改变。

`date_annotation=1` 是 Worker 调用 Qwen 的可选结果注释功能。它不属于
Python 图像处理任务，也不是“Windows 替代 RunPod”所必需的链路。排查
Scanner 的 `process/status/result` 时应先关闭这个变量，避免把两个问题混在一起。

## 2. `/api/process` 实际上传和返回什么

`POST /api/process` 的请求体是 `multipart/form-data`。其中最重要的内容是：

```text
image = 输入的原始 JPEG/PNG/WebP/HEIC 文件二进制
wb = 可选的白平衡开关
其他处理参数 = 按当前后端契约传递
```

这里上传的是输入图片，不是处理后的输出图片。输出拍立得图片不会放在
`POST /api/process` 的响应中，而是在任务完成后通过结果路由逐张下载。

Python 接收并创建任务后，`POST /api/process` 返回的是一小段 queued JSON，
形态如下：

```json
{
  "task_id": "<完整任务 ID>",
  "status": "queued",
  "white_balance": true,
  "postprocess_mode": "<当前模式>",
  "requested_polaroids": 0
}
```

字段可能随当前后端契约增加，但客户端至少必须取得 HTTP 200、`status:
queued` 和完整 task ID，才能继续轮询：

```text
GET /api/status/<完整任务 ID>
GET /api/result/<完整任务 ID>/<结果序号>
```

因此，“输出图片不到 2 MB”与最初的 `POST` 是否成功没有直接关系。出问题的
请求是上传数 MB 的原始图片；成功的 `POST` 响应本身只是很小的 JSON。

## 3. 启动阶段容易遇到的问题

### 3.1 脚本相对路径与当前目录不一致

从仓库根目录启动本地辅助脚本时，路径可以是：

```powershell
.\.venv\run-backend.ps1
.\.venv\run-wrangler.ps1
```

如果当前已经位于 `cloudflare-worker`，第二条相对路径不存在，应返回仓库
根目录，或使用与当前目录对应的路径。遇到“脚本不存在”时先运行：

```powershell
Get-Location
Test-Path .\.venv\run-wrangler.ps1
Test-Path ..\.venv\run-wrangler.ps1
```

不要通过复制脚本或另建 checkout 规避路径问题。

### 3.2 长运行进程在 Codex 子进程中不稳定

本次测试中，受限子进程启动的 workerd 无法正常读取 Worker 入口或写入
Wrangler 的用户级日志目录。对于需要持续观察 stdout 的 GPU 后端和
Wrangler，使用可见的 Windows Terminal 标签页更可靠：

- 一个标签页运行 Python；
- 一个标签页运行 Wrangler；
- 修改 Worker 或 `.dev.vars` 后停止旧进程，再明确启动新进程；
- 以两个标签页的当前 stdout 和监听 PID 为准，不以旧截图为准。

这不是开放端口或放宽安全边界的理由。Python 仍必须只监听 loopback。

### 3.3 Python 已监听不等于模型已就绪

Python 会先监听端口，再加载 SAM3。只有控制台明确显示 SAM3 已就绪并使用
CUDA 后，才可以提交真实任务。

模型缓存加载时可能出现“无法确认缓存文件 revision”的警告。如果随后正常
完成权重加载并显示 CUDA ready，该警告本身不代表启动失败；如果没有 ready
状态，则应停止测试并处理驱动、CUDA、模型下载或许可问题。

### 3.4 Wrangler 变量显示为 Hidden 是正常现象

Wrangler 启动时应确认以下本地 Scanner 配置均已加载，但不能显示其值：

```text
CHEKINANA_SCANNER_LOCAL_MODE
CHEKINANA_SCANNER_LOCAL_UPSTREAM
CHEKINANA_SCANNER_LOCAL_TOKEN
```

需要日期注释时，还应确认 Qwen 配置和 `CHEKI_DATE_RATE_LIMITER` binding
已加载。修改 `.dev.vars` 后必须重启 Wrangler；仅编辑文件不会更新已经运行
的进程。

客户端侧的忽略文件可使用以下占位形式：

```dotenv
CHEKINANA_WINDOWS_WORKER_BASE=http://<Windows 私网 IP>:8787
CHEKINANA_WINDOWS_SCANNER_TOKEN=<cloudflare-worker/.dev.vars 中的本地 token>
```

## 4. 首先验证监听、进程归属和隔离

在提交图片前运行：

```powershell
Get-NetTCPConnection -State Listen -LocalPort 8080,8787 |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

必须逐项确认：

- `8080` 的 `LocalAddress` 是 `127.0.0.1`；
- `8080` 的 PID 属于当前 checkout 启动的 Python；
- `8787` 的 PID 属于当前 `cloudflare-worker` 启动的 Wrangler/workerd；
- 重启前后的旧进程已经停止，没有多个实例争用端口。

然后分别检查：

1. Python loopback health 返回 HTTP 200；
2. 携带本地认证 header 的 Wrangler `/api/health` 返回 HTTP 200；
3. 错误 token 返回 401，且 Python 控制台没有收到请求；
4. Windows 私网地址的 `8080` 不可访问；
5. 防火墙没有开放 `8080`，`8787` 规则仅限 `Private/LocalSubnet`。

Worker 返回“processing”或客户端显示加载状态，不能证明 Python 已收到任务。
必须在 Python 控制台看到对应的“提交”、输入字节数和 `queued` 证据。

## 5. 本次最关键的故障：Python 已完成，但 Wrangler 返回 502

### 5.1 现象

同一路由出现了看似矛盾的结果：

- 极小的无效 multipart 图片经过 Wrangler 后，Python 收到请求并返回 400，
  Wrangler 也正确返回 400。
- 真实的 `4032×3024` JPEG 经过 Wrangler 后，Python 打印“提交”、图片
  字节数和 `queued`，GPU 随后完成任务。
- 客户端却收到 HTTP 502 和固定错误
  `local_scanner_upstream_unavailable`。
- 因客户端没有拿到 queued JSON，完整 task ID 丢失；Python 日志中的短前缀
  不能用于 `/api/status`。

这并不矛盾。创建任务是 Python 在收到 `POST` 后发生的副作用，而 502
发生在 Wrangler 处理上游响应时。代理失败不会回滚已经创建的 Python 任务。

### 5.2 为什么不能自动重试

对于 `POST /api/process`，502 不能简单理解为“上游没有收到请求”。本次故障
已经证明：

```text
客户端收到 502
  !=
Python 没有创建任务
```

自动重试会创建重复任务、重复消耗 GPU，并可能生成无法关联的结果。遇到
502 时应：

1. 不自动重试；
2. 立即查看 Python 是否出现一次“提交”和一次 `queued`；
3. 保存脱敏错误分类；
4. 先用不会创建任务的路由复现代理问题；
5. 确认修复并重启 Wrangler 后，再使用一张图片只提交一次。

## 6. 如何定位 502 发生在哪一阶段

排障时使用了仅限本地、最终删除的脱敏阶段诊断。禁止记录 URL、token、
图片、完整任务标识、模型响应或私网地址。

诊断结果是：

- `await fetch(upstreamRequest)` 已经返回；
- Python 直接响应的状态、JSON 类型和内容长度正确；
- queued JSON 可以直接解析，完整 task ID 格式正确；
- 异常出现在 Wrangler 构造或转发新的响应时；
- 尝试主动缓冲 `upstreamResponse.body` 会挂起；
- 直接返回上游响应也不能可靠修复。

原来的失败点表面上位于：

```js
return new Response(upstreamResponse.body, {
  status: upstreamResponse.status,
  statusText: upstreamResponse.statusText,
  headers: responseHeaders,
});
```

但这不是根因。`upstreamResponse.body` 在到达这里之前已经处于异常的传输
状态，单纯更换返回写法、复制 JSON 或缓冲 body 只是在移动故障位置。

## 7. 用“无任务副作用”的大请求隔离传输问题

真实 `/api/process` 每次都会创建 GPU 任务，不适合反复试错。更可靠的方法是：

1. 先直接向 Python 提交一次真实图片，确认其返回 HTTP 200、合法 queued
   JSON 和完整 task ID；
2. 再选一个不会创建图像任务、但仍会经过相同本地代理的大 multipart 路由；
3. 使用与真实图片相同量级的请求体；
4. 比较修复前后的 Wrangler 状态；
5. 只有无副作用复现通过后，才进行一次真实 `/api/process` 验证。

本次无任务大 multipart 复现同样返回 502，说明问题不在 SAM3、图片检测、
任务队列或 queued JSON 内容，而在 Wrangler/workerd 的大请求代理链路。

另一个重要经验是：PowerShell/.NET 的 `MultipartFormDataContent` 生成形式
可能与前端或 `curl -F` 不完全相同，曾因此得到与目标问题无关的 400。
需要复现真实客户端行为时优先使用：

```powershell
curl.exe --verbose `
  -H "X-Cheki-Token: <仅在内存中的本地 token>" `
  -F "image=@<绝对图片路径>" `
  -F "wb=1" `
  "http://<Windows 私网 IP>:8787/api/process"
```

命令只用于说明请求形态。不要把带真实 token 的命令、verbose 输出或 shell
历史保存到文档和日志中。

## 8. 已确认的根因

`curl.exe -F` 在上传较大的 multipart 时会加入：

```http
Expect: 100-continue
```

它用于 HTTP/1.1 的两阶段发送：客户端先发送请求头，等待服务器以临时
`100 Continue` 表示愿意接收请求体，然后再发送大 body。小文件通常没有这个
header，所以“小文件正常、大文件 502”具有明显的传输层分界。

本地 Worker 会先解析客户端 multipart，删除不可信的 `token` 字段，再创建
新的 `FormData` 和新的上游 `Request`。重建后会产生新的 boundary 和请求体，
原客户端的传输协商已经结束，不能继续照搬其 `Expect` 语义。

故障代码保留了客户端的 `Expect: 100-continue`，再把它放到重建后的
loopback 上游请求中。Windows 上的 workerd 因此进入异常的上游请求/响应流
状态：Python 实际已经收到 body、创建任务并返回 queued JSON，但 Worker
无法把该响应流可靠地交还客户端，最终落入本地代理的 502。

以下证据共同排除了“图片太大”和“Python JSON 错误”：

- 同一真实图片直接 POST Python 返回 200 和可解析的 queued JSON；
- Python 的监听 PID 在请求前后保持不变；
- 不创建任务的大 multipart 也能在 Wrangler 层复现 502；
- 更换 Wrangler 小版本不能消除问题；
- 删除 `Expect` 后，同一无任务大 multipart 从 502 变为 200；
- 删除 `Expect` 后，两张真实 `4032×3024` JPEG 均能各提交一次、轮询到
  `done` 并下载全部结果。

## 9. 最小且安全的修复

修复仅作用于 local Scanner 的 loopback 上游请求：

```js
const headers = copyHeaders(request);
headers.delete("x-cheki-token");
headers.delete("expect");
```

之后再清理客户端来源 header、解析并重建 multipart。这个位置保证：

- 本地认证完成后，token header 不进入 Python；
- 客户端 multipart 中的 `token` 字段仍被删除；
- 客户端伪造的 forwarding/IP headers 仍被删除；
- `Expect` 不会被复制到已经重建的 loopback 请求；
- 图片字节保持完全一致；
- 不改变生产 RunPod 分支；
- 不开放 `8080`，不绕过 Wrangler，也不降低认证强度。

回归测试应至少覆盖一个数 MB 的 multipart 文件，并验证：

- `X-Cheki-Token` 未转发；
- multipart `token` 字段未转发；
- `Expect` 未转发；
- 图片字节逐字节一致；
- Python 风格 queued JSON 完整返回；
- 客户端取得完整 task ID；
- 上游只调用一次，不产生重复任务。

## 10. 已尝试但不能作为修复的方法

以下方向曾被验证无效，或只能改变表象：

- 调整重建 multipart 的 `Content-Length`；
- 仅删除原 `Content-Length`；
- 使用固定长度 stream 包装请求体；
- 主动缓冲 `upstreamResponse.body`；
- 直接返回 `upstreamResponse`；
- 只改 `new Response(...)` 的构造方式；
- 降级 Wrangler；
- 用极小 Blob 的 mock 测试推断真实大文件一定正常；
- 反复提交真实图片观察是否“偶尔成功”。

这些尝试的共同问题是没有解释为什么 Python 已成功创建任务，也没有隔离
workerd 的真实 HTTP 状态机。mock 单元测试仍然必要，但不能替代 Windows
运行时的大 multipart 复现。

## 11. 正确的 Wrangler 日志顺序

正常情况下，从前端开始一次扫描后，Wrangler 日志大致应依次出现：

```text
OPTIONS /api/process 200        # 浏览器或 WebView 需要预检时才有
POST /api/process 200
GET /api/status/<已脱敏> 200    # 重复轮询
GET /api/result/<已脱敏>/<序号> 200
```

需要日期注释时，结果请求可能带 `date_annotation=1`，但返回的图片 body
仍是 Python 的原始结果图片，日期信息只体现在脱敏响应元数据中。

以下组合是本次故障的特征：

```text
Wrangler: POST /api/process 502
Python:   提交 -> queued -> GPU 完成
```

看到该组合时不要把 502 归类为“backend 未收到”，也不要立即重试。

## 12. Qwen 日期功能要单独判断

Wrangler 调用 Qwen 需要本地 Qwen API key、合法的 HTTPS base URL，以及
可用的 `CHEKI_DATE_RATE_LIMITER` binding。只确认配置加载时，不需要调用
Qwen 接口，也不应输出任何配置值。

常见固定错误分类：

- `service_unavailable`：Qwen 本地配置缺失或不合法，请求尚未进入模型服务；
- `rate_limit_unavailable`：限流 binding 缺失或不可用；
- `qwen_timeout`：模型请求超时；
- `qwen_unavailable`：模型服务不可用；
- `invalid_model_output`：模型输出不符合约定格式。

这些错误与 Python 是否接收 `/api/process` 无关。核心本地 GPU 验证先完成
`process -> status -> result`，日期注释再按需要单独验证。

## 13. 推荐的完整验证顺序

### 13.1 静态和自动化验证

```powershell
Set-Location .\cloudflare-worker
npm.cmd test
node --check .\src\worker.js
Set-Location ..
git diff --check
```

如果 PowerShell 执行策略阻止 `npm.ps1`，使用 `npm.cmd`，不要为此修改系统
级执行策略。

### 13.2 Windows 运行时验证

1. 停止所有旧 backend 和 Wrangler 实例。
2. 在可见终端中启动当前 checkout 的 Python。
3. 等待 SAM3 ready 和 CUDA ready。
4. 启动当前 checkout 的 Wrangler，确认本地变量和 binding 已加载。
5. 确认 `8080`、`8787` 的监听地址和 PID 归属。
6. 验证 Python health、Worker health、错误 token 和 `8080` LAN 隔离。
7. 发送极小无效图片，确认 Python 的 400 能原样通过 Wrangler 返回。
8. 使用无任务副作用的大 multipart 验证真实代理链路。
9. 核对真实 JPEG 的绝对路径、格式、尺寸和 SHA-256。
10. 每张真实图片只调用一次 `/api/process`。
11. 要求 HTTP 200、queued 状态和完整 task ID；ID 只保存在当前进程内存。
12. 轮询 `/api/status/<完整 ID>` 到 `done`。
13. 下载状态中列出的全部 polaroid 结果。
14. 校验结果图片尺寸和 SHA-256，生成不含标识符与私密地址的 manifest。
15. 如果任意一次 `/api/process` 返回 502，不重试，记录脱敏分类并停止。

建议把“提交、轮询、下载、生成 manifest”放在同一个脚本进程中。提交成功后
如果脚本因无关的输出格式或文件操作错误提前退出，而完整 task ID 又按安全
要求没有落盘，后续结果可能难以恢复。

## 14. 快速判定表

| 现象 | 最可能的层级 | 应先检查什么 | 不应做什么 |
| --- | --- | --- | --- |
| `8080` 无监听 | Python 启动 | backend 终端、模型加载、端口占用 | 开放防火墙 |
| `8080` 监听私网或 `0.0.0.0` | 安全配置 | `HOST=127.0.0.1` | 继续测试 |
| `8787` 无监听 | Wrangler 启动 | 当前目录、旧进程、启动 stdout | 直接访问 8080 |
| Worker health 401 | 本地认证 | header 与内存中的本地 token | 把 token 放进 URL/body |
| Worker health 503 | local 配置 | 三个本地变量的存在性和格式 | 修改生产配置 |
| 小图 400 且 Python 有日志 | 正常透传 | Python 的输入校验信息 | 把 400 当代理故障 |
| 大图 502 且 Python 无日志 | 请求发送前/连接 | PID、loopback、代理请求构造 | 自动重试多次 |
| 大图 502 且 Python 已 queued | 响应代理/传输状态 | `Expect` 清理、当前 Worker 代码、是否已重启 | 自动重试 |
| Python done，但没有完整 ID | 提交响应丢失 | 停止重试，修复代理 | 用 8 位日志前缀轮询 |
| 日期 `service_unavailable` | Qwen 配置 | key/base 是否已加载且格式合法 | 修改 Python |
| 日期 `rate_limit_unavailable` | Worker binding | `CHEKI_DATE_RATE_LIMITER` | 绕过限流 |

## 15. 最终经验

1. 端到端系统中，“上游完成副作用”和“客户端成功收到响应”是两个不同事件。
2. 对创建任务的 POST，代理 502 不能安全地自动重试。
3. 大文件与小文件行为不同时，要检查客户端自动添加的传输控制 header，而
   不只是图片字节、multipart boundary 和 `Content-Length`。
4. Worker 已经消费并重建 body 后，不能盲目复制原请求的传输协商 header。
5. 先用无副作用路由复现真实运行时问题，再消费 GPU 做最终验证。
6. mock 测试验证安全契约和字节一致性，Windows 真机测试验证 workerd 的
   HTTP 状态机；二者缺一不可。
7. 任何修复都必须保持认证、loopback 隔离、防火墙和生产路径边界。

