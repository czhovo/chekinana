# Handoff

## From

Agent role: Frontend

## Task ID

BATCH-FE-009

## Summary

Aligned Frontend pre-task upload cancellation with the Backend canonical route.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Updated `PRE_TASK_UPLOAD_CANCEL_PATH` from `/api/upload-attempts` to `/api/upload-cancel`.
  - change: Updated `cancelUploadAttempt(uploadAttemptId)` to call `POST /api/upload-cancel/<upload_attempt_id>` without the old `/cancel` suffix.

## Behavior Changed

Timed-out uploads and user interrupts before `/api/process` returns a backend `task_id` now send the Backend canonical pre-task cancel request:

```text
POST /api/upload-cancel/<upload_attempt_id>
body: { "upload_attempt_id": "<upload_attempt_id>" }
```

The existing post-task cancel path remains unchanged:

```text
POST /api/cancel/<task_id>
```

Upload timeout/retry limits, upload attempt ids, stale callback guards, rotated thumbnails, active-task status display, incremental results, ordered batch behavior, auth, contact UI, result download, and save behavior were left unchanged.

## API Contract Changes

Frontend now uses the canonical Backend `BATCH-BE-003` pre-task upload cancel endpoint:

- `POST /api/upload-cancel/<upload_attempt_id>`

The mismatched `/api/upload-attempts/<upload_attempt_id>/cancel` route is no longer used by Frontend code.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
git diff --check
node -e mocked canonical upload cancel route check
node -e mocked timeout canonical cancel route check
node -e mocked interrupt-before-task canonical cancel route check
```

Results:

```text
node --check passed.
git diff --check passed.
Mocked canonical upload cancel route check passed: cancelUploadAttempt("attempt-route") calls /api/upload-cancel/attempt-route.
Mocked timeout canonical cancel route check passed: timed-out upload aborts, sends /api/upload-cancel/<attempt_id>, and still retries within the configured limit.
Mocked interrupt-before-task canonical cancel route check passed: interrupt before task id aborts upload, sends /api/upload-cancel/<attempt_id>, and ignores late upload success.
```

## Risks / Follow-up

- Full WeChat DevTools verification was not available in this agent environment.
- Reviewer should pair this with Backend `d765c72` to confirm the canonical route rejects late `/api/process` arrivals with canceled `upload_attempt_id`.

## Notes For Next Agent

- Scope is limited to Frontend endpoint alignment for `BATCH-FE-009`.
- No Backend files, auth/token routing, upload retry limits, active-task status logic, result APIs, contact UI, or save/download behavior were changed.
