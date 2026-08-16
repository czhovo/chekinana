## Current Goal

完成并交付本轮 Worker 生产部署、Hidden Idol、Review 即时刷新与同日 Event 自动关联；后续优先补 iOS 未运行的 focused/UI 覆盖，不操作真机数据。

## Latest User Instructions

- 检查 Cloudflare Worker/RunPod 代理日志，解释 `backend startup connection was interrupted`。
- 检查最近数十次日期识别全部失败的原因，并部署已修改的 Worker。
- Idol 可隐藏；其自身及任何包含它的 Cheki/Shame/Douga 在所有业务位置不可见，唯一恢复入口为 Settings 隐藏列表。
- Review 手动修改人物/日期等要立即显示生效。
- 新 Cheki 在未显式指定 Event 时，自动关联 canonical 同日唯一 Event。
- Assistant 不新增 birthday 行；addidol API birthday 只修解析/保存链。
- Scanner/GPU 空闲自动关闭延长到4分钟；Event详情图片可全屏查看；Import Cheki尺寸与方向独立处理。

## Repository State

- Checkout: repository root
- Branch: `main`，共享 dirty worktree；必须保留全部其他改动。
- 未 commit/push。
- Cloudflare Worker production version 80 已于上海时间 2026-08-13 04:21 部署并承接 100% 流量。
- 物理 iPhone 保持此前恢复的 old clean app；本轮 iOS 新代码未安装真机，未修改设备数据。
- 磁盘当前约 26 GiB 可用，无需清理用户/共享缓存。

## Active Architecture And Contracts

- Worker production 包含 ScannerRuntime DO、日期独立接口、Qwen 90s、24KiB 分块 base64、abort 传播、cancel tombstone、typed commands；`scanner-runtime-v1` migration/tag/class/binding保持。
- `startup_disconnected` 仅表示最后一个 startup WebSocket 已断开，不证明 RunPod Start API/Pod/backend 失败。历史 Observability 未启用，无法还原既往 close code/HTTP 状态。
- 日期历史失败没有保留分类日志，无法区分 Qwen timeout/unavailable/invalid output 等；缺少 `CHEKI_DATE_RATE_LIMITER` 不是原因，生产 bundle 不含该 guard。
- Hidden Idol 使用非 schema、versioned UserDefaults UUID set；任何 record 的 idols 与 hidden set 有交集则整条不可见。Event 本身可见，只隐藏/不计相关 records。Settings → Hidden Idols 是唯一 Unhide 入口。
- Hidden record 仍参与真实 idx/collision 计算；所有 resolver/write/confirmation refetch 拒绝 hidden Idol。
- Review ledger 是唯一事实源；编辑后必须 `update → reconcile → unconditional refresh`。
- Event intent 三态：unspecified/selected/cleared。仅 unspecified 新 Cheki 按 canonical 同日恰好1个 Event 自动关联；0或多个保持nil；显式选择/clear优先。Attach existing 保留已有 Event。
- Birthday String 三态仍为 nil、`yyyy-MM-dd`、`--MM-DD`；API DTO入口规范化，invalid候选不入ledger/store；Assistant布局不增加birthday行。
- Scanner idle auto-shutdown为240,000ms；用户Stop20s及其它startup/active/cancel timer不变。
- Import Cheki先EXIF归正再应用input quarterTurns，各一次；mini/wide按方向无关比例推断并等比aspect-fit。Mini P/L 1200×1908/1908×1200；Wide P/L 1908×2400/2400×1908；unknown保持方向且ledger size nil。
- Event图片viewer按UUID打开，支持分页、1–4x缩放、下拉或Close关闭，不改存储。
- GPU startup public status在preparing时可带`progress:{current,total:3}`：1检查/启动控制，2等待Pod，3已RUNNING等待strict health；其它状态不带progress。iOS显示Preparing x/3，旧/畸形字段回退普通Preparing。

## Authoritative References And Routing

- Trigger: Scanner startup interruption/date failures/Worker部署。完整阅读：`cloudflare-worker/src/scanner-runtime.js`、`cloudflare-worker/src/worker.js`、`cloudflare-worker/src/cheki-date-annotator.js`、`cloudflare-worker/wrangler.toml`。生产version 80已部署；历史日志不足，不能过度归因。
- Trigger: Hidden Idol。完整阅读：`ChekinanaPresentation.swift` hidden store/policy；`ChekinanaProductShell.swift` roots/Settings/pickers；`ChekinanaCommandExecutor.swift` resolver/confirm；`ChekinanaConversationCoordinator.swift`、`ContentView.swift`、`ChekinanaChekiRokuImportWizard.swift`。
- Trigger: Review即时刷新/Event自动关联。阅读 ProductShell Review paths 与 CommandExecutor ledger/event policy；明确 quick/full editor 都要从最终ledger刷新。
- Trigger: Idol birthday/addidol Unknown。阅读 ProductShell BirthdayValue、IdolEnrichmentClient DTO、CommandExecutor Catalogue normalizer；禁止新增Assistant birthday行。
- Trigger: 真机birthday转换。不得直接重试；current V4无法打开active V4 store，须先在真实store副本证明reopen兼容。
- Carry forward: Scan Input/Review均逆时针旋转；无媒体Shame/Douga真机删除仍未执行。
- Trigger: Import Cheki尺寸/方向。阅读ProductShell LocalImport processor/media loader/Review preview及CommandExecutor temporary ledger；禁止固定portrait拉伸或固定mini。

## Scope And Non-Goals

- Scope: Worker部署及只读诊断；iOS Hidden/Review/Event/birthday链代码。
- Non-goals: 主动触发RunPod/GPU/日期业务请求、真机安装/数据修改、再做birthday维护hook、猜测历史日志根因。

## Current Changes

- Worker: scanner runtime/date/NL/Event/idle4及startup progress相关当前diff已部署version 80。
- iOS: Presentation/DataModel/CommandExecutor/ProductShell/ConversationCoordinator/ContentView/ChekiRokuWizard/xcstrings/tests 接入hidden、event policy、review refresh及birthday链。
- Hidden持久不改SwiftData schema；DataModel仅import/调用非schema registry相关代码。

## Completed This Window

- Worker candidate：serial tests 399/399、syntax/diffcheck/dry-run PASS；Reviewer approved；deploy PASS；production metadata/content确认100% active。
- 日志诊断：生产bundle证实startup WS语义；60s live tail 0 events；无历史Observability/本地相关日志，明确不可判既往具体根因/次数。
- Hidden：中央registry、主要UI roots、Settings hide/unhide、pickers、Assistant/resolver/confirm/ChekiRoku写防线完成；generic build PASS。
- Review：full/quick Idol/Date/Event编辑均统一reconcile后无条件刷新；Reviewer P1修复approved。
- Event：Review单存/Save all、single confirm、Calendar Add、Assistant addrecord/album finalize、Scan、ChekiRoku等接unique same-day policy；显式select/clear与attach优先级接入。
- Addidol birthday：API DTO边界规范化，invalid隔离，nil不覆盖existing；Assistant布局零改；generic build PASS。
- Idle4：focused77/77、full404/404、dry-run/deploy/content核验PASS；version79 active。
- Event viewer：点击/分页/缩放/关闭/invalid placeholder完成，generic/diff/catalog PASS，Reviewer approved。
- Import Cheki：横竖canvas、aspect-fit、size贯穿ledger/save完成；方向/no-stretch/wide canvas focused、generic/diff/catalog PASS，Reviewer approved。
- Startup progress：Worker scanner82/full409、dry-run/deploy/content PASS；iOS generic/BFT/focused3/3 PASS；Reviewer approved，production v80 active。

## Pending Work

1. 补 Hidden 全UI矩阵与深deeplink专项验证；核心读写/迟到结果合同已完成。
2. 补 Event 各入口更广泛的0/1/2、select、clear、date change、attach集成测试；核心policy与quick路径已通过targeted tests。
3. 下一次自然生产请求可用实时tail收集安全诊断；不要主动启动GPU。
4. 真机birthday转换保持禁止，直到真实V4 store副本reopen问题解决。

## Subagent State

- Backend：部署与只读诊断完成。
- Frontend：实现完成，generic/diff/catalog通过；部分focused待跑。
- Reviewer：Worker deploy approved；iOS最终 P1窄修 approved。

## Verification State

- Worker serial full: 399/399 PASS；dry-run/deploy/production content verification PASS。
- iOS generic Simulator build: PASS。
- iOS focused: hidden persistence/any-member visibility、unique same-day event 2/2 PASS。
- 最终targeted focused：quick-date自动/显式Event、no-op reconcile refresh、hidden late any-member 3/3 PASS；此前hidden persistence/unique same-day 2/2 PASS。
- iOS diffcheck/catalog JSON: PASS。
- 未跑长UI/真机/network/GPU。

## Risks

- Hidden set在UserDefaults而非SwiftData；只迁移数据库不迁移App defaults时隐藏状态不会随库恢复。
- Hidden变化时Scan/Review立即过滤temporary cards并关闭草稿；protect/publish边界重验，迟到hidden结果不进入Review；仅best-effort清temporary ledger，不删除持久化数据。
- 深层deeplink/statistics未逐页运行验证。
- 生产部署改善date链，但未通过主动业务请求验证历史全失败已消失；下一次自然请求需观测。
- 共享dirty worktree仍包含大量未提交跨任务改动。

## External Archive Candidates

- Birthday wireless pre/post backups仅保存在本机临时目录；不能直接用于写回。
- 无媒体 Cheki 备份仅保存在本机、不入库。

## Resume Prompt

恢复本轮任务：先完整阅读本文件。Worker已部署version 80，不重复部署；Import不得回退固定portrait/mini。若用户自然复现startup/date失败，用wrangler live tail只读收集白名单字段，禁止主动启动RunPod/GPU或暴露标识。
