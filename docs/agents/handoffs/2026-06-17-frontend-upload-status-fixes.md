# Handoff

## From

Agent role: Frontend

## Task ID

BATCH-FE-008

## Summary

Fixed rotated thumbnail display, bounded image upload timeout/retry behavior, pre-task upload interrupt/cancel handling, and active-task-based queue/processing status display.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added upload timeout/retry constants and a shared upload wrapper that generates `upload_attempt_id`, aborts timed-out uploads when possible, sends pre-task cancel, retries within the configured limit, and then returns a normal upload failure to the existing batch partial-failure flow.
  - change: Added pre-task upload cancel on user interrupt before a backend `task_id` exists while preserving existing `/api/cancel/<task_id>` behavior after a task id is known.
  - change: Updated status handling to use backend active task fields such as `active_task_id` / `processing_task_id`; another active task shows queued/waiting, the current active task shows detecting/loading as `图片处理中`, and extracting shows `正在提取第 x 张 (x/N)` even before the first result.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Thumbnail images now render from `previewPath` when available, matching the same rotated preview source used by the large preview.

## Behavior Changed

Thumbnail previews now reflect each selected image's own rotated preview state. Uploads include a unique `upload_attempt_id` in `/api/process` form data.

Upload timeout/retry constants:

```text
UPLOAD_TIMEOUT_MS = 45000
UPLOAD_MAX_RETRIES = 1
PRE_TASK_UPLOAD_CANCEL_PATH = /api/upload-attempts
```

On upload timeout, the frontend aborts the current `wx.uploadFile` task when possible, calls:

```text
POST /api/upload-attempts/<upload_attempt_id>/cancel
body: { "upload_attempt_id": "<upload_attempt_id>" }
```

Then it retries once with a fresh `upload_attempt_id`. If the retry also times out, single-image processing fails with an upload timeout message, while batch processing records the image failure and continues to later selected images.

If the user taps `中断` before `/api/process` returns a backend `task_id`, the frontend aborts the active upload task when possible, sends the same pre-task cancel signal, stops further uploads, and ignores late upload callbacks. If a `task_id` already exists, the existing `POST /api/cancel/<task_id>` path remains in use.

Queue/processing status now follows backend active task id fields rather than `queue_position` alone. `queue_position: 0` no longer forces a queued display. When the backend reports the current `task_id` as active in loading/detecting phases, the UI shows `图片处理中`; when extracting, it shows extraction progress using backend target counts.

## API Contract Changes

Frontend now depends on the new Backend `BATCH-BE-003` pre-task upload cancel contract:

- `/api/process` form field: `upload_attempt_id`
- pre-task cancel endpoint: `POST /api/upload-attempts/<upload_attempt_id>/cancel`
- JSON body: `{ "upload_attempt_id": "<upload_attempt_id>" }`

Frontend also reads backend active task fields from `/api/status/<task_id>` when present:

- `active_task_id`
- `activeTaskId`
- `processing_task_id`
- `processingTaskId`
- `active_processing_task_id`
- `activeProcessingTaskId`

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
git diff --check
node -e mocked upload timeout/retry/pre-task cancel check
node -e mocked interrupt during upload before task id check
node -e mocked active-task queue/detecting/extracting status check
node -e mocked normal sequential batch behavior check
Select-String selected-image-thumb previewPath check
```

Results:

```text
node --check passed.
git diff --check passed.
Mocked upload timeout/retry/pre-task cancel check passed: timeout aborts upload, cancels the attempt id, retries once with a fresh attempt id, and proceeds when retry returns a task id.
Mocked interrupt during upload before task id check passed: interrupt aborts active upload, sends pre-task cancel, stops processing, and ignores a late upload success.
Mocked active-task queue/detecting/extracting status check passed: another active task shows queued without queue position 0, current active detecting shows 图片处理中, and current active extracting shows 第1张 progress before results.
Mocked normal sequential batch behavior check passed: selected upload order, per-image failure continuation, ordered task-scoped results, and partial-success status are preserved.
Thumbnail markup uses item.previewPath before item.path.
```

## Risks / Follow-up

- Full WeChat DevTools visual verification was not available in this agent environment.
- Backend `BATCH-BE-003` must implement the matching pre-task cancel endpoint and active task id fields documented above.

## Notes For Next Agent

- Scope is Frontend-only for `BATCH-FE-008`.
- No backend files, auth/token routing, RunPod startup, extraction internals, contact UI, result download, or save behavior were changed.
