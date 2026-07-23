# Chekinana

Chekinana 当前主产品是一款面向 iOS 17+ 的本地 Idol、Event 与 Cheki 整理 App。用户通过单屏自然语言界面查询或添加 Idol、创建 Event、从相册添加 Cheki，或调用 Scanner 提取照片中的拍立得。

自然语言解释、公开资料查询和图片提取由云端服务辅助；对象匹配、候选确认、数据写入和图片管理由 App 在本地完成。所有新增内容都必须先经过用户确认，才会写入本地数据库。

## 当前产品：iOS App

iOS App 使用 SwiftUI、SwiftData 和 PhotosUI 构建，支持 iPhone 与 iPad。主界面不是传统 tab 结构，而是一张连续的对话界面：

- 顶部显示 `Chekinana`。
- 中间 transcript 展示文字、澄清选项以及 Idol、Event、Cheki 卡片。
- 底部输入框支持文字发送和最多 9 张相册图片。
- 四个快捷入口可预填“添加 Idol”“微博建 Event”“扫描照片”“查看 Cheki”。
- 远端解释和 Event 提取有忙碌、取消、错误与重试状态；照片读取有忙碌、取消和错误提示，失败后需要重新提交或重新选择。

普通产品请求采用 remote-first 的自然语言解释流程，因此即使是查看本地数据，当前也需要网络完成意图解释。

## 当前已支持的操作

### Idol

- 按名称查询公开 Idol catalogue。
- 单候选时显示确认卡，多候选时要求用户明确选择。
- 候选卡显示名称、团体、生日和认证信息。
- 确认后保存到本地 SwiftData。
- 列出或查看已保存 Idol，并显示关联 Cheki 数量。

当前 v1 自然语言入口支持添加、列出和查看 Idol；已保存 Idol 的编辑、删除尚未作为可用 UI 能力开放。

### Event

- 使用名称和日期创建 Event，URL 可选。
- 从公开 Weibo 状态链接提取 Event 候选。
- 提取结果包含 7 个可编辑字段：名称、日期、城市、场地、Weibo URL、票务 URL、备注。
- 在候选阶段执行 URL、字段长度和疑似详细地址等本地校验。
- 用户确认后保存，并可列出或查看已保存 Event。

候选写入前可以编辑；已保存 Event 的编辑和删除尚未通过当前 v1 自然语言入口开放。

### Cheki

从相册添加 Cheki：

1. 先通过自然语言选择一个或多个本地 Idol。
2. 选择一个 Event，或使用日期作为归档依据。
3. 从系统相册选择最多 9 张图片。
4. 每张图片生成待确认 Cheki 卡。
5. 用户确认且图片与 SwiftData 都写入成功后，Cheki 才会持久保存。

已保存 Cheki 包含关联 Idol、Event 或日期、组内自动序号、用户是否入镜、尺寸、备注和本地图片引用。用户可以按 Idol、Event 或日期列出 Cheki，也可以查看单张详情。

点击 Cheki 图片会打开黑底全屏预览。预览优先读取本地保存原图，失败时退回卡片缩略图；打开或关闭预览不会改变 Cheki 的选择状态。

当前 v1 UI 尚未开放已保存 Cheki 的编辑、删除或导出到系统相册。

## Scanner 工作流

Scanner 用于从普通照片中检测并提取拍立得：

1. 在输入区选择最多 9 张照片并发送扫描请求。
2. App 依次上传图片、轮询任务状态并下载 `polaroid` 结果。
3. 用户可以在扫描前打开默认关闭的“识别并标注手写日期”开关。
4. 开启后，Cloudflare Worker 在取得单张 RunPod 结果时调用一次 Qwen；日期识别失败不会阻断原图片下载。
5. App 根据返回的日期和 `[0,1000]` 归一化 bbox，在图片上本地绘制绿色标注框，不修改原图。
6. 下载结果转换为 JPEG，只进入当前进程的内存临时区，不立即写入数据库。
7. 用户为结果选择一个或多个 Idol，以及一个 Event 或日期。
8. 每张结果经过确认后才保存为持久 Cheki。

临时结果区限制为 20 张、100 MB、30 分钟。未被待确认操作引用的旧结果会被释放，App 重启后临时结果也会丢失。

识别出的日期属于单张 Cheki 自身的可空手写日期元数据，不复用归档用的 `eventDate`，也不会修改共享 Event、Cheki 分组或序号。完整日期与只有月日的结果分别保留为 `YYYY.MM.DD` 和 `MM.DD`；App 不会猜测缺失年份。标注框和文字只是 UI overlay，原图、缩略图和本地图片引用保持不变。

Scanner 请求使用独立的 `X-Cheki-Token` 认证边界。Scanner 凭据只从未跟踪的本地构建配置注入，不会进入自然语言请求、源码、README 或测试夹具。当前客户端取消只保证停止本地任务，不保证已经提交的服务端任务同步终止。

日期识别开关开启时，单张 Scanner 结果图片会在 Cloudflare 内转发给 Qwen。Qwen API Key 与兼容接口地址只由 Worker secret 持有，不会下发到 iOS；每个结果最多调用一次且不自动重试。

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
- Scanner 日期文字和 bbox 作为 Cheki 自身的可空元数据保存，不改变 Event/date 归档关系。
- 待确认操作和 Scanner 临时结果只存在当前进程内。
- 当前没有账号登录、CloudKit、云端数据同步或跨设备恢复。

## 云服务边界

| 能力 | 云端职责 | iOS 本地职责 |
| --- | --- | --- |
| 自然语言 | `POST /api/nl/interpret`，返回严格的 v1 `plan / clarify / reject` | 隐私过滤、schema 校验、对象匹配、澄清与执行 |
| Idol | 查询公开 catalogue | 候选选择、确认、SwiftData 持久化、列表与详情 |
| Weibo Event | `POST /api/event/weibo-candidate`，提取七字段候选 | 字段编辑、安全校验、确认与保存 |
| Scanner | 上传、轮询、结果下载；可选将单张结果交给 Qwen 识别日期 | 选图、开关控制、凭据注入、bbox overlay、临时结果、关联与持久化 |
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

随后在本地配置 `CHEKINANA_SCANNER_POD_ID`。`Secrets.xcconfig` 已被忽略，不得提交、粘贴到 Issue/PR，或记录到日志和截图中。未配置 Scanner 时，App 会在读取照片和发起 Scanner 网络请求前本地拒绝操作。

Cloudflare 日期识别在每个目标 Worker 环境中需要配置：

- secrets：`CHEKI_DATE_QWEN_API_KEY`、`CHEKI_DATE_QWEN_BASE_URL`
- 独立限流 binding：`CHEKI_DATE_RATE_LIMITER`
- 非敏感模型配置：`CHEKI_DATE_QWEN_MODEL=qwen3.7-plus`

当前生产 Worker 已配置两个 secrets 和独立的 `CHEKI_DATE_RATE_LIMITER`；真实 secret 与私有接口地址不进入仓库。限流 binding 缺失或异常时，Worker 不会调用 Qwen，但仍会原样返回 RunPod 图片，并把日期识别标记为不可用。

## 验证状态与已知限制

- 工程包含单元测试、UI 测试和额外的 command contract / translator parity harness。
- 当前日期标注改动的 iOS `build-for-testing` 已通过；这只证明 App 与测试 target 可以编译，不代表全部 XCTest 都已执行。
- Cloudflare Worker 全量 mock 测试 272/272 通过，其中日期标注 focused tests 49/49；没有产生真实 Qwen 费用。
- Scanner 单元测试使用 mock；此前真实链路已验证可以生成临时 Cheki 结果，但未据此宣称端到端保存、相册导出和失败恢复均已人工验证。
- 日期标注 Worker 已部署到生产，secrets、独立 limiter、route、CORS 和无外部调用的边缘 smoke 已验证；尚未执行真实 RunPod→Worker→Qwen 付费 smoke、验证已有 SwiftData store 迁移或在模拟器中手动演示 overlay。
- 本次 iOS 日期开关、元数据持久化和 bbox overlay 仍是本地未提交代码，尚未通过 TestFlight 或 App Store 发布。
- Cheki 全屏预览已有单元测试、UI fixture 和 Reviewer 审查，但尚未在真实模拟器中手动演示。
- 真实网络 smoke test 默认跳过，需要显式环境授权。
- 单结果 Idol 候选头像依赖已有图片缓存；缓存未预热时可能显示占位头像。
- 已保存 Idol、Event、Cheki 的编辑/删除以及 Cheki 相册导出代码尚未接入当前 v1 意图白名单，不应视为已交付 UI 功能。

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
