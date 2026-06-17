# Handoff

## From

Agent role: Frontend

## Task ID

BATCH-FE-012

## Summary

Fixed batch completion shortage summaries, post-completion preview navigation, completed action copy, and bounded upload socket/TLS failure handling.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Preserves completed result/action state while switching preview images after processing.
  - change: Lists all per-image shortage failures in the final batch status instead of only the first shortage.
  - change: Retries `wx.uploadFile` fail callbacks up to the existing max-2 retry limit, cancels each pre-task upload attempt id, and sanitizes socket/TLS failures for user-facing status text.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Renamed completed action text from `删除全部图片` to `新任务`.
  - change: Hides count input while completed/failed action buttons are visible.
- `docs/agents/handoffs/2026-06-18-frontend-completion-upload-regressions.md`
  - change: Added this handoff.

## Behavior Changed

Final batch status now includes every source image whose received result count is below its expected count, for example:

```text
批量处理完成，共提取 5 张，图片1结果不足：已收到 3/4 张；图片2结果不足：已收到 2/4 张
```

After processing completes, preview arrows and thumbnail taps only change the current preview image; they no longer clear extracted results, failed source markers, completed status, or the completed action buttons. Upload socket/TLS failures follow the same bounded retry path as upload failures and end with a generic network retry message instead of raw low-level error text. The completed reset action is now labeled `新任务` while keeping the existing behavior: successful source images are cleared and failed source images are preserved when present.

## API Contract Changes

None. Existing `/api/process`, `/api/status/<task_id>`, `/api/result/<task_id>/<result_id>`, `/api/upload-cancel/<upload_attempt_id>`, `/api/cancel/<task_id>`, auth, contact, and `polaroid_size` upload behavior remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node - <mock script>
git diff --check
```

Results:

```text
node --check passed.
Mock checks passed: multiple shortages, post-completion navigation preserving results/status/actions, TLS/socket upload fail retry/sanitization, 新任务 label and failed-source preservation, all-download visiting every extracted result, and polaroid_size upload regression coverage.
git diff --check passed.
```

## Risks / Follow-up

- Real-device verification should confirm the observed screenshot TLS/socket failure now shows the sanitized retry/failure path instead of staying on upload forever.
- The low-level upload failure is still logged to the developer console for debugging, but it is no longer surfaced as user-facing status text.

## Notes For Next Agent

- `setCurrentImageIndex` now detects completed action state through existing extracted results or failed source markers and preserves all completion fields during preview navigation.
- `getShortageSummaryText` joins all shortage failures with `；` so partial extraction shortages are visible together.
