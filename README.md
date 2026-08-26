# Chekinana

Chekinana 是一款面向 iOS 17+ 的 Idol、Event 与拍立得整理 App。它以本地数据为主，将人物资料、活动、Cheki、Shame、Douga 和相关媒体统一管理，并提供扫描识别、日历、Gallery、批量导入和自然语言 Assistant。

iOS App 使用 SwiftUI、SwiftData 和 PhotosUI 构建，支持 iPhone 与 iPad。主要数据和图片保存在当前设备；仅在用户主动启动识别、资料查询或 Assistant 时请求对应云端服务。

## 当前版本状态

- iOS 版本：`1.0 (1)`，最低支持 iOS 17.0。
- 快照日期：2026-08-27。
- 本快照是统一 `MediaItem` 数据模型迁移前的可回退基线；SwiftData 最新 schema 为 V12，`Cheki`、`Shame` 和 `Douga` 仍是三个独立实体。
- Travel 已接入独立部署的 Schedule 查询服务，并支持航空公司、国铁与 JR 图标；普通业务数据仍只保存在本机。该公开服务由 `api.chekinana.top/api/v1/schedule*` 的更具体 Cloudflare route 承载，不属于本仓库 `cloudflare-worker/` 中的 Scanner/Assistant Worker 实现。
- **待更新：Scan 识别算法。** 当前 Scan 流程仍可使用，但识别算法、阈值和相关模型合同尚未作为最终版本冻结，后续更新不得以本快照的识别表现作为最终标准。

本节只描述该 GitHub 快照的版本边界，不代表后续本地开发中的未提交迁移状态。

## iOS App 功能总览

底部导航包含五个主页面：

1. **Scan**：从相机、系统相册或已经裁切的 Cheki 图片建立扫描任务。
2. **Idols**：管理 Idol 资料、头像、生日、pattern 和关联记录。
3. **Calendar**：按日期查看、统计和编辑 Cheki、Shame 与 Douga。
4. **Events**：管理活动资料、图片和关联 Cheki。
5. **Gallery**：按类型浏览、筛选、编辑、导出和删除媒体记录。

左上角侧边栏还可进入 Assistant、Settings、ChekiRoku 导入和内置小游戏。

## Scan 与拍立得识别

Scan 可以从包含多张拍立得的普通照片中提取 clean Cheki，也可以直接导入已裁切图片。

- Camera、Photos 和 Import Cheki 三种输入方式。
- 每张输入图片都有独立的逆时针旋转和删除按钮；点击图片本身不会触发删除。
- Camera/Photos 使用 SAM3 Scanner 提取拍立得；Import Cheki 跳过 GPU 提取，但会统一处理 EXIF、用户旋转、画布方向与 mini/wide 尺寸。
- 日期识别和 Idol 识别可独立开关。
- 日期识别结果可包含完整日期或只有月日。Qwen 不会为原图中缺失的年份臆造文本；iOS 会依据用户设定的固定日期、日期范围或最近一年候选范围将月日解析为完整 canonical 日期；无法唯一落入候选范围时保持未识别。
- Idol 识别在设备端对图片编码，并与用户选定候选 Idol 的本地 patterns 比较。
- Scanner Runtime 公开状态为 Offline / Preparing / Ready；启动过程在 Preparing 后显示 `1/3`、`2/3`、`3/3`。
- GPU 在没有扫描活动后等待 4 分钟自动关闭；用户手动停止与自动关闭是两套独立流程。

识别结果先进入 Review，不会直接写入数据库。Review 中可以：

- 逐张逆时针旋转 clean 图片。
- 立即修改 Idol、日期、Event、idx、尺寸、备注、收藏、SNS 状态和用户是否入镜。
- 在图片中只显示临时日期 bbox；保存、导出和下载的 clean 图片不包含该标注。
- 日期对应恰好一个 Event 时自动关联；没有、存在多个、用户明确选择或清空时都不会猜测。
- 只有用户点击保存后，数据与媒体文件才会持久化。

单张失败会与其他结果隔离；日期不可用时仍保留 clean 图片，只要至少一张结果有效就可继续 Review。

## Idol 管理

- 手动添加 Idol 时仅 `name` 必填；头像、团体、生日、参考图和其他资料均可选。
- 可以从公开 catalogue 搜索资料，检查候选后再保存。
- 生日支持完整日期 `yyyy-MM-dd` 和年份未知 `--MM-DD`；只有月日的 Idol 不需要伪造年份。
- 已有的 `X月X日`、`MM.dd`、`M/D` 值会按“年份未知”语义显示和编辑。
- 未知年份模式只选月、日；切换到完整日期必须显式确认年份，不会把 2000 或当前年当作真实生日。
- 头像保存为 App 受管本地图片。Catalogue 候选可从受信任的远程 URL 下载头像，但持久化前会本地化；所有 Idol 头像入口都统一为完整圆形裁切。
- 一个 Idol 可保存多个本地 pattern，供 Scan 候选识别使用。
- Idol 按收藏状态分组，并在组内固定按 Cheki 总数从多到少排序；当前列表不允许拖动调整顺序。可以从详情进入按日期分组的 Cheki。
- Idol 可以隐藏。隐藏后，该 Idol 及任何包含它的 Cheki、Shame、Douga 都不在业务页面、统计、选择器或 Assistant 中显示。
- 唯一恢复入口是 Settings 中的 Hidden Idols 列表；恢复后原有关系、序号和媒体保持不变。

## Calendar

- 月视图按日期显示当天的可见记录数量。
- 选中日期后先展示当天 Event，Cheki 再按 Idol 分组展示，并保留媒体缩略图。
- 可从日历直接批量添加 Cheki；无媒体 Shame/Douga 不会在这里创建。
- 对同一 Idol 组的无媒体 Cheki，可以直接调整数量和备注，并在一次事务中维持日期组 `idx` 连续。
- 未定日期记录保持 `idx=nil`；迟到关系或元数据变更会使批量编辑失效，防止部分写入。
- 语言切换后，当前月份、选中日期和滚动位置保留，页面文案立即更新。

## Events

- Event 支持名称、日期、城市、Livehouse、地址、票价、Weibo URL、票务 URL、备注和头像。
- 新建 Event 时可从受支持的公开 Weibo 状态链接提取候选字段；提取结果仍需要用户检查和保存。
- Event 可保存多张图片。点击图片可打开全屏查看器，支持左右切换、1–4 倍缩放、下拉或按钮关闭。
- Event 详情中的 Cheki 先按完整 Idol UUID 集合分组，同一 Idol 组的多张 Cheki 合并为一行，数量使用“张 / 枚”等本地化量词。
- 点击分组后进入该组的 Cheki 列表，单张仍可打开原有详情与编辑。
- 新 Cheki 在没有明确 Event 意图时，只会自动关联同日唯一 Event。明确选择、明确清空和编辑已有 Cheki 都不会被自动规则覆盖。

## Gallery 与记录类型

Gallery 分别管理：

- **Cheki**：Gallery 仅展示带本地图片的 Cheki。Calendar/Assistant 可创建无媒体 Cheki 数量记录，这些记录从 Calendar 或 Idol 页面访问。
- **Shame**：新记录必须包含图片。
- **Douga**：新记录必须包含视频引用。

共同能力包括：

- 按记录类型和 Idol 筛选；Cheki 额外支持收藏和 solo/2-shot 筛选。
- 关联一个或多个 Idol；只要其中一个 Idol 被隐藏，整条记录都不可见。
- 编辑元数据、查看本地媒体、导出 clean Cheki 图片和安全删除。
- 点击 Cheki 图片打开浅色背景的详情预览，并读取 App 受管的本地图片。
- Cheki 分组序号按真实全量数据计算；隐藏记录仍参与唯一性与下一个 `idx` 计算，避免重复序号。

## ChekiRoku 导入

- 读取 ChekiRoku 导出记录并先生成可审核计划。
- 只导入 Cheki 类型；Shame/Douga 源记录在解析、统计和写入阶段均会被跳过，不会作为错误中断。
- 可保留多 Idol 关系、日期、备注和与已有记录的数量衔接。
- 提交时会在最终 ModelContext 中重新校验，避免预览后数据变化导致错配。

## Assistant

Assistant 使用自然语言转换为严格的 typed operations。它可以协助：

- 列出、查看、添加、编辑、收藏或删除 Idol。
- 列出、查看、添加、编辑或删除 Event。
- 列出、查看、添加、编辑或删除 Cheki/Shame/Douga。
- 导航到主要产品页、打开 Scan，或从相册建立扫描任务。
- 处理澄清、候选选择、待确认操作、取消、错误和重试。

安全边界：

- 模型只返回类型化意图与字段，不会获得 SwiftData 对象、本地媒体文件、Scanner token 或确认码。
- 对象查找、重名选择、hidden 校验、关系校验和最终写入都在 App 本地完成。
- 有副作用的操作会先生成确认项，确认时再次从当前 ModelContext 取回对象，拒绝过期或不可见目标。
- 无媒体 Shame/Douga 创建会在确认之前被拒绝；已有 legacy 记录仍可查看、编辑或删除。

## Settings 与本地化

- 设置页当前提供跟随系统、简体中文和日本语；English 本地化内容仍保留在代码中，但语言选项暂时隐藏。
- 从 Settings 退出后，当前页面、五个底部导航项和已打开的详情页立即更新，不需要重启 App 或重载页面。
- 语言切换不会重建 ModelContainer，已选日期、导航、编辑草稿和页面状态会保留。
- Hidden Idols 管理页是唯一恢复隐藏 Idol 的位置。
- 可查看本地对象数量、Scanner Runtime 状态和关键配置是否可用。

## 本地数据与隐私

- Idol、Event、Cheki、Shame 和 Douga 使用 SwiftData 保存在当前设备。
- Cheki 图片、Shame 图片、Douga 视频引用、Event 图片和 Idol 头像由 App 的受管媒体目录管理。
- 数据库与媒体写入使用尽可能原子化的提交/回滚边界，不会为了恢复启动而自动挂载一个空库。
- 隐藏 Idol UUID 集合保存在 App 的 versioned preferences 中，不改变 SwiftData schema。
- Scanner 临时结果仅存在当前进程，受容量与过期策略保护，App 重启后会消失。
- 当前没有账号登录、CloudKit、云端数据同步或跨设备恢复。

## 云端能力边界

| 能力 | 云端职责 | iOS 本地职责 |
| --- | --- | --- |
| Assistant | Worker 调用 DeepSeek 解释自然语言，返回严格 typed plan | 隐私过滤、对象匹配、澄清、确认和执行 |
| Event 候选 | Worker 抓取受支持的公开 Weibo 资料并调用 DeepSeek 提取字段 | 展示候选、编辑、本地校验与保存 |
| Idol catalogue | 查询公开资料 | 规范化生日、选择头像、确认与持久化 |
| Scanner | Worker/Durable Object 管理 RunPod 生命周期，Backend 使用 SAM3 提取拍立得 | 输入管理、Review、设备端 Idol 编码、纠正与保存 |
| 日期识别 | Worker 调用 Qwen 返回日期与 bbox | 临时 overlay、人工纠正与最终日期保存 |
| Travel 时刻 | 独立 Schedule Worker 的更具体 Cloudflare route 返回公开计划时刻 | 查询、站点选择、图标、本地行程保存 |
| 普通数据 | 不提供云同步 | SwiftData 与媒体文件全部由当前设备管理 |

Travel 的 Schedule Worker 是同域名下的独立部署依赖，不包含在本仓库的
`cloudflare-worker/` 源码中。部署这里的 `api.chekinana.top/*` 通配 Worker 前，
必须确认更具体的 `api.chekinana.top/api/v1/schedule*` route 仍指向 Schedule
Worker；否则 Travel 查询不可用。本仓库只保存 iOS 客户端的严格请求、响应和错误
解析合同。

除 Assistant 与 Event 候选提取外，其他功能不会请求 DeepSeek。日期识别使用独立 Qwen 配置，Scanner 使用 RunPod/Backend/SAM3。

## 开发与构建

要求：

- macOS + Xcode
- iOS 17.0+
- Swift 6
- Xcode 工程：`ios/Chekinana/Chekinana.xcodeproj`
- Scheme：`Chekinana`
- iOS App 无第三方 Swift Package 依赖

构建：

```sh
xcodebuild \
  -project ios/Chekinana/Chekinana.xcodeproj \
  -scheme Chekinana \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

本地可选秘密配置：

```sh
cp ios/Chekinana/Config/Secrets.example.xcconfig \
  ios/Chekinana/Config/Secrets.xcconfig
```

`Secrets.xcconfig` 已被 Git 忽略。真实 token、API key、Pod ID、Backend 凭据和私有 endpoint 不得加入仓库、Issue、PR、日志或截图。生产 iOS App 不保存 RunPod Pod ID 或 Scanner/Backend token；这些凭据由 Worker 服务端边界持有。

Worker 和 Backend 的详细配置、合同、测试与运维方法见：

- [`cloudflare-worker/README.md`](cloudflare-worker/README.md)
- [`docs/windows-lan-gpu-backend.md`](docs/windows-lan-gpu-backend.md)
- [`docs/windows-lan-gpu-backend-troubleshooting.md`](docs/windows-lan-gpu-backend-troubleshooting.md)

## 验证

当前仓库包含：

- iOS unit tests、UI tests 与 command contract harness。
- Cloudflare Worker 的日期、Event、Assistant、Scanner 代理、Runtime 与取消行为测试。
- Backend 的拍立得裁切、pattern 分类、部分失败隔离和回调测试。

最近的本地合并验证包括：

- Generic iOS Simulator build：PASS
- Cloudflare Worker tests：421/421 PASS
- Backend focused tests：22/22 PASS
- Date annotation tests：62/62 PASS
- Scanner recognition tests：12/12 PASS

默认测试不请求真实 DeepSeek/Qwen，不启动 RunPod/GPU，也不操作真机数据。

## 仓库结构

```text
ios/Chekinana/          # 当前 iOS App、单元测试和 UI 测试
cloudflare-worker/      # Assistant、Event、日期识别、Scanner Runtime 与代理
backend/                # Scanner/SAM3 图像处理运行时
scripts/                # 检查、验证和运维辅助脚本
cloudflare-pages/       # 静态资源与相关服务内容
wechat-miniprogram/     # 历史微信小程序实现
nginx/                  # 可选反向代理配置
```

## 历史微信小程序

仓库仍保留微信小程序版本，包括 Scanner、Calendar、Idols、小游戏和 Settings 等旧实现。它不是当前活跃客户端，本轮 iOS 开发不会同步修改该目录。

历史说明见 [`wechat-miniprogram/README.md`](wechat-miniprogram/README.md)。
