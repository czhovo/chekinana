# Handoff

## From

Agent role: Frontend

## Task ID

BATCH-FE-006

## Summary

Fixed batch processing-time UX so preview navigation remains usable, running work can be interrupted, partial polling results display immediately, and processing status text shows the target count with "正在提取第几张" wording.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added processing run IDs, active task tracking, interrupt handling, backend cancel calls, stale callback guards, canceled-status handling, and immediate batch partial-result merging from `/api/status/<task_id>`.
  - change: Allowed thumbnail taps and left/right preview navigation while processing without clearing current results or processing status.
  - change: Updated single and batch processing status text to use "正在提取第几张" with `(m/n)` target count when available.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Replaced the `添加图片` button with `中断` while processing.
- `wechat-miniprogram/pages/index/index.wxss`
  - change: Added scoped interrupt button styling.

## Behavior Changed

While a batch is running, users can still tap selected-image thumbnails and the preview left/right controls to inspect other selected images. These navigation actions update the preview only; they do not clear already returned results or reset the active processing status.

When processing is active, the left toolbar button becomes `中断`. Tapping it immediately stops the current frontend run, clears the polling timer, invalidates pending callbacks, preserves any visible extracted results, shows an interrupted status, and calls `POST /api/cancel/<task_id>` when a backend task id is active. After interruption, stale upload or poll callbacks do not resume polling or upload later images.

Batch polling now merges newly returned polaroid results into the result grid as soon as they appear in `/api/status/<task_id>`, before the current source image reaches its final completion state. Existing selected-image order, task-scoped result keys, failure-continue behavior, auth headers, upload form fields, result download, save behavior, and contact-author UI are preserved.

## API Contract Changes

Frontend now calls the Backend cancellation endpoint:

```text
POST /api/cancel/<task_id>
```

The request uses the existing protected API auth header from `getAuthHeader()`.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node -e mocked batch interrupt/incremental UX check
node -e mocked sequential batch failure-continue check
git diff --check
```

Results:

```text
node --check passed.
Mocked batch interrupt/incremental UX check passed: partial polling result displayed immediately, preview navigation stayed usable during processing, interrupt called /api/cancel/taskA, preserved visible results, and stale polling did not start later uploads.
Mocked sequential batch failure-continue check passed: images still upload in selected order, a middle upload failure does not stop the next image, task-scoped ordered results remain intact, and final partial-success status is preserved.
git diff --check passed.
```

## Risks / Follow-up

- Full WeChat DevTools visual verification was not available in this agent environment.
- Backend `BATCH-BE-002` must provide the protected cancel endpoint and canceled/cancelled status contract described in the taskboard.

## Notes For Next Agent

- This is scoped to Frontend processing UX and cancellation wiring only.
- No Backend files, auth/token routing, RunPod startup, SAM extraction behavior, contact-author UI, result save behavior, or production gateway config were changed.
