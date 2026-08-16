# Chekinana

Chekinana 当前主产品是一款面向 iOS 17+ 的本地 Idol、Event 与 Cheki 整理 App。用户可直接通过 Scan、Idols、Events、Gallery 与 Calendar 页面浏览或处理本地内容，也可从左侧边栏进入完整 Assistant，使用自然语言查询或添加对象。

自然语言解释、公开资料查询和图片提取由云端服务辅助；对象匹配、候选确认、数据写入和图片管理由 App 在本地完成。所有新增内容都必须先经过用户确认，才会写入本地数据库。

## 当前产品：iOS App

iOS App 使用 SwiftUI、SwiftData 和 PhotosUI 构建，支持 iPhone 与 iPad。App 启动后进入原生产品界面：

- 底部导航包含 Scan、Idols、Events、Gallery 与 Calendar；这些页面直接读取本地 SwiftData，不需要先经过自然语言解释。
- 左上角菜单打开类似 ChatGPT iOS 的覆盖式侧边栏，可进入 Assistant、Calendar 或 Settings，并显示本机对象数量。
- Scan 页面直接完成选图、日期/Idol 识别、候选范围、临时结果纠正和确认保存，不要求进入 Assistant。
- Idols、Events、Gallery 与 Calendar 提供本地搜索、筛选、增删改、详情、关联 Cheki、空态和数据态；Settings 只显示真实的本地存储与 Scanner 配置状态。
- Assistant 保留原有 transcript、澄清/确认卡片、底部输入框、不限张数的相册选择、快捷入口以及忙碌、取消、错误与重试状态。

Assistant 中的普通自然语言请求仍采用 remote-first 的解释流程；底部各产品页的本地浏览、搜索和筛选不依赖该解释服务。

## 当前已支持的操作

### Idol

- 按名称查询公开 Idol catalogue。
- 单候选时显示确认卡，多候选时要求用户明确选择。
- 候选卡显示名称、团体、生日和认证信息。
- 确认后保存到本地 SwiftData；选择参考图片时，原图在设备端编码为一个 256 维 pattern，并作为头像保存。
- 一个 Idol 可以保存多个 pattern；内置 12 个固定原型对应 11 个预设 Idol，其中 `mina` 与 `mina_new` 合并为 `mina（凌晨12点）`。
- 原生 UI 可列出、查看、编辑和安全删除 Idol，并从 Idol 详情进入关联 Cheki；有关联 Cheki 时拒绝删除。

### Event

- 使用名称和日期创建 Event，URL 可选。
- 从公开 Weibo 状态链接提取 Event 候选。
- 提取结果包含 9 个可编辑字段：名称、日期、城市、livehouse、Weibo URL、票务 URL、票价、备注和 Event 头像；票价保留多档文本，头像来自受信任的微博作者图片元数据。
- 在候选阶段执行 URL、字段长度和疑似详细地址等本地校验。
- 用户确认后保存，并可按未来、过去和未定日期查看 Event。
- 原生 UI 可手动添加、编辑和安全删除 Event，并从 Event 详情进入关联 Cheki；有关联 Cheki 时拒绝删除。

### Cheki

从相册添加 Cheki：

1. 在原生表单中选择一个或多个本地 Idol。
2. 选择一个 Event，并填写日期作为归档依据。
3. 从系统相册选择图片；UI 不设置固定张数上限。
4. 每张图片生成待确认 Cheki 卡。
5. 用户确认且图片与 SwiftData 都写入成功后，Cheki 才会持久保存。

已保存 Cheki 包含关联 Idol、日期、可选 Event、组内自动序号、用户是否入镜、尺寸、备注和本地图片引用。用户可以按 Idol、Event 或日期列出 Cheki，也可以查看单张详情。

点击 Cheki 图片会打开黑底全屏预览。预览优先读取本地保存原图，失败时退回卡片缩略图；打开或关闭预览不会改变 Cheki 的选择状态。

原生 Gallery 可编辑已保存 Cheki、重新计算变更分组后的 `idx`、安全删除，并把不含 bbox 的干净图片导出到系统相册。

## Scanner 工作流

Scanner 用于从普通照片中检测并提取拍立得：

1. 输入区保留同尺寸的 Camera 与 Photos 入口，并可横向拖出第三个 Import Cheki 入口；开始处理前可逐张删除待处理图片，也可一次清空，临时结果只受本地容量保护约束。Import Cheki 跳过 SAM3 提取，后续图片调整和识别流程与 clean 拍立得一致。
2. App 会尽早提交全部源图，并以 250 ms 间隔轮询各任务状态；某张 clean `polaroid` 首次出现在 `status.results` 时就立即且仅一次发起该结果下载，不等待整个提取任务完成。同一任务新发布的结果没有固定并发上限，最终仍按源图和后端首次发布顺序处理。Python Backend/RunPod 只负责 SAM3 提取，不做日期识别、图片编码或 Idol 分类。
3. 日期识别与 Idol 识别是两个可独立开关的前端功能，首次进入 Scan 时两者默认开启；`unassigned` 默认不加入候选范围，用户可手动开启。
4. 日期识别开启时，Camera/Photos 的标准 SAM3 链路仍在单张 result GET 上附加 `date_annotation=1`，由 Worker 标注该结果并通过响应头返回日期和 `[0,1000]` 归一化 bbox。只有 Import Cheki 在本地处理后，把 raw PNG 提交到独立 `POST /api/cheki/date-annotation` 并接收等价 JSON；该独立路由不查询、不启动也不代理 RunPod。普通 result GET 不会调用 Qwen。
5. Idol 识别开启时，App 在设备端用编码器生成图片向量，并只在 `candidates` 指定的、已保存原型的 Idol 与 `unassigned` 中比较；自动结果最多填写一个 Idol。
6. 每张返回图片生成一个内存临时 Cheki：图片、可选单个 Idol 和可选日期来自识别结果；不分配 `idx`，`userAppears` 与其他未识别字段保持空值或默认值。
7. App 只在临时预览上绘制日期 bbox。原图、下载到系统相册的图片和最终持久图片都不包含标注框。
8. 用户可以纠正 Idol/日期/Event、填写其他字段或删除某个临时 Cheki；识别日期只对应唯一 Event 时自动关联，且可在编辑器中去除或更换；多 Idol 关联只允许用户手动补充。
9. 用户确认后才写入 SwiftData，并按相同 Idol 与日期组合从 `1` 开始分配 `idx`；最终 Cheki 不保存 bbox 或 Scanner Pattern ID。

扫描遮罩会显示当前源图编号、后端队列/读取/SAM 检测/逐张提取阶段、本图已发布与已获取数量、累计已获取与已准备数量，以及本机编码分类和预览生成阶段。结果 GET 完成后，JPEG 转换与 Idol 编码并行执行，不再把本机处理误报为“后端正在提取”。

失败按最小单元隔离：Python 中某个检测候选无法裁切或编码时继续处理其余候选；iOS 中某张源图、某个结果 GET、某张无效图片或 Idol 分类失败时继续保留其他有效图片。日期识别不可用只留下空日期并保留 clean 图片；只要至少一张结果有效就进入临时结果页，只有全部结果均不可用时扫描才整体失败。部分失败不会回退为未经提取的源图。

临时结果区没有固定张数上限，容量保护为 100 MB，生存期为 30 分钟。未被待确认操作引用的旧结果会按容量或过期状态释放，App 重启后临时结果也会丢失。

识别出的日期用于单张 Cheki 的 `date`。完整日期与只有月日的结果分别保留为 `YYYY.MM.DD` 和 `MM.DD`；对 `MM.DD`，App 按设备当前时区确定最近一个不晚于今天的有效 Gregorian 日期，包括跨年和闰日回退；Qwen 仍不为原图中缺失的年份臆造文本。Event 仍可作为普通关联属性，但不再参与 Cheki 的 Idol/日期/序号身份组合。bbox 只存在于临时 UI overlay，原图、缩略图、本地图片引用和最终 Cheki 都不保存 bbox。

生产 Scanner 请求不再由 iOS 提供 Pod ID 或 Scanner/backend token。Cloudflare Worker 的 Durable Object 在服务端保存当前 Pod ID，由 Worker 代理请求并只向 Python Backend 注入对应凭据；iOS 只处理 `closed`、`preparing`、`ready` 三种公开状态，并依据服务端 Boolean `canStart` / `canTerminate` 决定是否开放控制。`phase` 与公开 `state` 同值，内部 RunPod 失败、迁移与终止阶段不会下发。只有 Windows Wrangler 的显式 local Scanner mode 继续要求客户端通过未跟踪的本地构建配置提供 local `X-Cheki-Token`。生产 RunPod API key、Pod ID 与 Backend 凭据不会进入自然语言请求、iOS 源码、README 值或测试夹具。当前客户端取消只保证停止本地任务，不保证已经提交的服务端任务同步终止。

日期识别开关开启时，Camera/Photos 提取结果通过带 `date_annotation=1` 的 result GET 在 Cloudflare 内交给 Qwen；只有 Import Cheki 使用独立 raw-PNG POST。Qwen API Key 与兼容接口地址只由 Worker secret 持有，不会下发到 iOS；日期路径没有专用访问频率限制，iOS 对每张图片只请求一次，Worker 只调用一次 Qwen 且不自动重试。Qwen 不可用时，两条路径都保留 App 可继续处理的原图，分别以固定响应头或固定 `unavailable` JSON 表达日期不可用。

## 自然语言与确认机制

当前 v1 schema 支持 11 种意图：

- Idol：添加、列出、查看。
- Event：添加、列出、查看。
- Cheki：扫描照片、从相册添加、保存扫描临时结果、列出、查看。

缺少 Idol、Event、日期或临时扫描结果时，App 会显示本地澄清控件；同名本地对象有多个匹配时，用户必须从候选中选择。确认、取消和清空 transcript 在本地处理。

发往自然语言服务的内容限于用户文字、当前日期、时区以及完成请求所需的最小 draft。相册图片、Scanner 凭据和确认码不会发送到自然语言服务；疑似凭据 URL、token/header 文本和 Scanner 配置会在本地拒绝。

## 本地数据与图片

- Idol、Event 和 Cheki 使用 SwiftData 保存在当前设备。
- Cheki 原图原子写入 App 的 Application Support 目录。
- 缩略图和全屏预览由 App 在本地生成。
- Scanner 日期可作为 Cheki 的 `date` 保存；bbox 只属于临时预览，不写入 Cheki 或图片。
- 待确认操作和 Scanner 临时结果只存在当前进程内。
- 当前没有账号登录、CloudKit、云端数据同步或跨设备恢复。

## 云服务边界

| 能力 | 云端职责 | iOS 本地职责 |
| --- | --- | --- |
| 自然语言 | `POST /api/nl/interpret`，返回严格的 v1 `plan / clarify / reject` | 隐私过滤、schema 校验、对象匹配、澄清与执行 |
| Idol | 查询公开 catalogue | 候选选择、确认、SwiftData 持久化、列表与详情 |
| Weibo Event | `POST /api/event/weibo-candidate`，提取九字段候选 | 字段编辑、安全校验、确认与保存 |
| Scanner | Python Backend/RunPod 只提取 clean 拍立得；Worker 管理 Runtime，通过 opt-in result GET 标注 SAM3 结果，并通过独立 raw-PNG POST 标注 Import Cheki | 选图与开关、设备端编码和候选 Idol 分类、bbox 临时 overlay、属性纠正、临时结果与持久化 |
| 普通数据 | 不提供云同步 | Idol、Event、Cheki 和图片全部保存在本机 |

## 开发与配置

要求：

- iOS 17.0+
- Swift 6
- Xcode 工程：`ios/Chekinana/Chekinana.xcodeproj`
- Scheme：`Chekinana`
- 无第三方 Swift Package 依赖

构建：

```sh
xcodebuild \
  -project ios/Chekinana/Chekinana.xcodeproj \
  -scheme Chekinana \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Scanner 需要本地秘密配置：

```sh
cp ios/Chekinana/Config/Secrets.example.xcconfig \
  ios/Chekinana/Config/Secrets.xcconfig
```

生产配置不需要、也不允许在 iOS 中保存 Pod ID 或 Scanner/backend token；App 默认请求由 Worker/Durable Object 托管凭据的生产代理。只有 Windows Wrangler Debug local mode 才在被忽略的 `Secrets.xcconfig` 中配置 `CHEKINANA_LOCAL_SCANNER_TOKEN` 与本地 `CHEKINANA_SCANNER_BASE_URL`。该文件不得提交、粘贴到 Issue/PR，或记录到日志和截图中。

Cloudflare 日期识别在每个目标 Worker 环境中需要配置：

- secrets：`CHEKI_DATE_QWEN_API_KEY`、`CHEKI_DATE_QWEN_BASE_URL`
- 非敏感模型配置：`CHEKI_DATE_QWEN_MODEL=qwen3.7-plus`

日期识别不再需要独立 rate-limiter binding。独立 raw-image 路由不依赖 RunPod，兼容的 Scanner-result opt-in 路径仍由 Worker/Durable Object 的服务端边界保护；每个请求最多执行一次 Qwen 调用。真实 secret 与私有接口地址不进入仓库；自然语言与 Event 路径的独立限流保持不变。

### Scanner 跨端部署顺序

Runtime 三态、两个控制字段和独立日期路由构成跨端 breaking contract，必须按以下顺序发布：

1. 先部署新 Cloudflare Worker。
2. 用生产 `GET /api/scanner/runtime` 确认 `state` 与 `phase` 只会是 `closed`、`preparing` 或 `ready`，并确认 `canStart`、`canTerminate` 都存在且为 Boolean；同时确认 `POST /api/cheki/date-annotation` 路由已生效。
3. 上述检查通过后，才可发布依赖该合同的新 iOS App。

不得反序发布。新 iOS 对缺失的 control 字段一律 fail closed；若旧 Worker 仍在运行，Runtime 控制会保持禁用，Camera、Photos 和 Import Cheki 的日期识别也不可用。生产请求无论新旧均由 Durable Object/Worker 在服务端持有 RunPod 身份，这一发布约束与客户端 Pod ID 或 token 无关。

## 验证状态与已知限制

- 工程包含单元测试、UI 测试和额外的 command contract / translator parity harness。
- 当前 iOS `build-for-testing` 已通过；这只证明 App 与测试 target 可以编译，不代表全部 XCTest 都已执行。
- Cloudflare Worker mock 测试覆盖独立 raw-image 日期路由、兼容日期 opt-in、普通请求零 Qwen、本地/生产代理、原图正文不变及三态/controls 元数据；测试不会产生真实 Qwen 费用。
- Scanner 单元测试使用 mock；此前真实链路已验证可以生成临时 Cheki 结果，但未据此宣称端到端保存、相册导出和失败恢复均已人工验证。
- Runtime 三态/controls、60 秒延迟手动关闭、五分钟 idle 关闭和独立日期路由已于 2026-08-05 部署到生产 Worker。部署后四次间隔只读检查均返回公开 `preparing` / `preparing`，两个 controls 均为 `false`，没有再暴露旧内部 phase；method rejection/OPTIONS 也确认了独立日期路由及 CORS。验证没有上传图片、调用真实 Qwen 或触发 RunPod 生命周期操作。尚未执行真实 RunPod→Worker→Qwen 付费 smoke、验证已有 SwiftData store 迁移或在模拟器中手动演示 overlay。
- 本次 Scanner 日期/Idol 开关、设备端识别、临时 bbox overlay 和确认流程仍是本地开发状态，尚未通过 TestFlight 或 App Store 发布。
- Cheki 全屏预览已有单元测试、UI fixture 和 Reviewer 审查，但尚未在真实模拟器中手动演示。
- 真实网络 smoke test 默认跳过，需要显式环境授权。
- Idol 头像支持受管本地图片与远程 URL；网络不可用且远程图片未缓存时会显示名称占位头像。
- 已保存 Idol、Event、Cheki 的编辑/删除以及 Cheki 相册导出已通过原生 UI 开放；自然语言意图白名单是否支持同一操作不影响这些 UI 能力。

## 仓库结构

```text
ios/Chekinana/          # 当前 iOS App、单元测试和 UI 测试
cloudflare-worker/      # 自然语言、Event、鉴权与代理服务
backend/                # Scanner 图像提取运行时
scripts/                # 提取、翻译、验证和部署辅助脚本
cloudflare-pages/       # 静态资源与相关服务内容
wechat-miniprogram/     # 历史微信小程序实现
nginx/                  # 可选反向代理配置
```

## 历史微信小程序

仓库仍保留微信小程序版本，包括 Scanner、Calendar、Idols、小游戏和 Settings 等实现；它不是当前活跃客户端。相关说明见 [`wechat-miniprogram/README.md`](wechat-miniprogram/README.md)。
