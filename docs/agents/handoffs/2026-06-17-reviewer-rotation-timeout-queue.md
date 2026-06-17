## Findings

- P1 BLOCKING `wechat-miniprogram/pages/index/index.js:986`
  提取结果少于用户输入的期望数量时，结束后的状态栏仍可能不显示“结果不足”。单图轮询完成路径使用 `this.getBackendExpectedCount(payload) || fallbackExpectedCount` 计算最终目标数；但 Backend 在检测到的拍立得少于用户输入数量时，会把 `total_polaroids` / `expected_polaroids` 设为实际检测数量。因此用户输入 5 张、Backend 实际检测并返回 3 张时，Frontend 得到的 `expectedCount` 会变成 3，`completedImages.length < expectedCount` 不成立，最终走 `finishWithImages()`，状态栏不会显示 3/5 不足。
  Owner: Frontend

- P1 BLOCKING `wechat-miniprogram/pages/index/index.js:743`
  批量轮询完成路径存在同样问题：`getBackendExpectedCount(payload)` 优先使用 Backend 的实际 `total_polaroids`，覆盖了用户输入的 `fallbackExpectedCount`。这会让某张批量图片少提取时仍被视为完成成功，`finishBatchExtract()` 也拿不到 shortage failure，最终状态栏不显示不足数量。
  Owner: Frontend

## Open Questions

无。

## Verification

- 确认工作区为 `C:\Users\20888\Desktop\chekinana-reviewer`，分支为 `codex/reviewer-next`。
- 已复核 `BATCH-FE-010` / `BATCH-REV-007` 相关提交：
  - PM `e9d4f38` -> local `2940f6c`
  - Frontend `9105b7f` -> local `0d7999b`
  - Frontend `c056be0` -> local `6915b28`
  - Frontend `3163107` -> local `5530061`
- 已复核 Frontend handoff `docs/agents/handoffs/2026-06-17-frontend-rotation-timeout-queue.md`。
- 已定位实际失败链路：
  - `backend/app.py:615` 记录检测数量少于用户输入数量时的 warning。
  - `backend/app.py:652` / `backend/app.py:653` 在提取阶段把 `expected_polaroids` / `total_polaroids` 设置为实际检测到的 `len(all_vertices)`。
  - `backend/app.py:696` / `backend/app.py:697` 在完成阶段继续把 `total_polaroids` / `expected_polaroids` 设置为实际提取数量。
  - `wechat-miniprogram/pages/index/index.js:1119` 的 `getBackendExpectedCount()` 优先返回 `payload.total_polaroids`。
  - `wechat-miniprogram/pages/index/index.js:986` 和 `wechat-miniprogram/pages/index/index.js:743` 因此会让 Backend 实际数量覆盖用户输入的 `fallbackExpectedCount`。
- 上一轮通过的检查仍说明其他部分未发现新问题，但不足数量完成态验证不充分：
  - `node --check wechat-miniprogram/pages/index/index.js` passed。
  - `git diff --check HEAD~4..HEAD` passed。
  - Mocked checks covered rotation fallback/no-canvas behavior, keyed preview switching, 15-second timeout with 2 retries, queued copy, active-task status, all-download, clear-successful-images, failed-image preservation, `/api/upload-cancel/<upload_attempt_id>`, and `/api/cancel/<task_id>`。
- 需要 Frontend 补充 targeted mocked check：当用户输入期望 5 张、Backend 完成 payload 返回 `total_polaroids: 3` / `expected_polaroids: 3` / `extraction_complete: true` 且结果数为 3 时，最终状态栏必须显示收到/期望 `3/5`，并保留 3 张 partial results。

## Verdict

changes requested
