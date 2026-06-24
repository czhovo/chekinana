# Handoff

## From

Agent role: Frontend

## Task ID

PICK-FE-001

## Summary

Switched scanner image selection to the real-WeChat-compatible `wx.chooseImage` path with result normalization and safe picker failure handling.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Uses `wx.chooseImage` for image-only selection, preserving album/camera sources, original image size, max 9 images, and add-more behavior.
  - change: Keeps a `wx.chooseMedia` fallback only when `wx.chooseImage` is unavailable.
  - change: Normalizes `tempFilePaths`, `tempFiles[].tempFilePath`, and `tempFiles[].path` into the existing selected-image model.
  - change: Treats picker cancel as a no-op, logs raw non-cancel picker errors to console, and shows a concise user-facing failure toast.
- `docs/agents/handoffs/2026-06-21-frontend-image-picker.md`
  - change: Added this handoff.

## Behavior Changed

Adding images now uses `wx.chooseImage` before upload or backend processing begins. Successful picker results from either `chooseImage` or fallback `chooseMedia` flow through the same selected-image normalization path, so existing per-image defaults remain intact: count, rotation, `polaroid_size`, and `postprocess_mode` continue to be initialized as before.

User cancellation no longer shows a failure toast. Non-cancel picker failures still log the raw picker error for debugging, but the UI only shows:

```text
选择图片失败，请重试
```

## API Contract Changes

None. This fix happens before `wx.uploadFile`, `/api/process`, and backend task creation. Existing upload fields, retry/cancel behavior, status polling, result ordering, completed navigation, all-download, failed-source preservation, auth, tab navigation, calendar route, and `izaya7-map` route remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\izaya7-map\izaya7-map.js
node - <mock script>
git diff --check
git show 7f5c47e -- | git patch-id --stable
git show 838aeba -- | git patch-id --stable
```

Results:

```text
node --check passed for recommended files.
Mock checks passed: chooseImage path, user cancel no-op, non-cancel failure logging/toast, chooseMedia fallback, result normalization, add-more after existing images, and 9-image limit.
git diff --check passed.
Patch-id matched for 7f5c47e and already-synced 838aeba, confirming the PM briefing/taskboard content was already present in this synced worktree.
```

## Risks / Follow-up

- Real-device QA should confirm the previously failing album-selection path no longer fails before images are added.
- Fallback to `wx.chooseMedia` is intentionally limited to environments without `wx.chooseImage`; normal real-WeChat image selection should stay on `wx.chooseImage`.

## Notes For Next Agent

- The fix is scoped to the picker and selected-image state normalization. No backend work is expected for this issue.
- Do not reintroduce old `pages/izaya-map` references; main sync uses `pages/izaya7-map`.
