# Handoff

## From

Agent role: Backend

## Task ID

BATCH-BE-003

## Summary

Added backend active-task status fields and a protected pre-task upload-attempt cancellation contract for timed-out or interrupted uploads before a `task_id` exists.

## Files Changed

- `backend/app.py`
  - change: tracks the single worker's active task id, exposes it in `/api/status/<task_id>`, stores optional upload attempt ids on tasks, adds protected upload-attempt cancellation endpoints, and rejects late `/api/process` arrivals for pre-canceled upload attempts.
- `docs/agents/handoffs/2026-06-17-backend-upload-status-contract.md`
  - change: records Backend implementation and verification notes for `BATCH-BE-003`.

## Behavior Changed

`/api/status/<task_id>` now includes these new fields:

```json
{
  "active_task_id": "currently-processing-task-id-or-empty-string",
  "processing_task_id": "same value as active_task_id",
  "upload_attempt_id": "attempt id associated with this task, if provided"
}
```

The worker sets `active_task_id` when it starts a task and clears it after that task's raw data cleanup. While the active task is in `loading`, `detecting`, or `extracting`, status responses for any task expose that active task id.

New protected upload-attempt cancellation endpoints:

```text
POST /api/upload-cancel/<upload_attempt_id>
POST /api/upload-cancel
```

For `POST /api/upload-cancel`, the upload attempt id may be sent as JSON, form, or query field:

```json
{
  "upload_attempt_id": "frontend-generated-attempt-id"
}
```

The backend also accepts camelCase `uploadAttemptId`.

`POST /api/process` now accepts optional multipart fields:

```text
upload_attempt_id
uploadAttemptId
```

If `/api/process` arrives after that attempt id was canceled, the backend returns `409` with `status: "canceled"` and does not create, queue, or extract a task. Normal uploads without an attempt id, or with a non-canceled attempt id, remain compatible.

## API Contract Changes

Added protected upload-attempt cancel contract and additive status fields:

- `POST /api/upload-cancel/<upload_attempt_id>`
- `POST /api/upload-cancel`
- `/api/status/<task_id>` now includes `active_task_id`, `processing_task_id`, and `upload_attempt_id`.
- `/api/process` may include optional `upload_attempt_id` or `uploadAttemptId`; existing requests without those fields still work.

Existing auth/token behavior, `/api/cancel/<task_id>`, `/api/process` normal response compatibility, RunPod startup, extraction internals, and result endpoints are unchanged.

## Verification

Commands run:

```text
git cherry-pick da1124b
python -m py_compile backend\app.py
git diff --check
Taskboard hash check: git show HEAD:docs/agents/taskboard.md | git hash-object --stdin; git show da1124b:docs/agents/taskboard.md | git hash-object --stdin
Focused Flask smoke with mocked torch/flask_cors/scipy.spatial:
  - active task id appears on active task status
  - queued task status exposes a different active task id
  - active task id is empty after clearing active worker state
  - unauthorized upload cancel is rejected
  - protected upload cancel records attempt id
  - late /api/process for pre-canceled attempt returns canceled 409 and is not queued
  - normal /api/process with attempt id still queues
  - normal /api/process without attempt id still queues
```

Results:

```text
py_compile: passed
git diff --check: passed
taskboard hash: 018429ab6577504976cb288e23c40909422b9d26 == 018429ab6577504976cb288e23c40909422b9d26
active_status_fields 200 processing detecting active-task active-task
queued_mismatch_fields 200 queued 1 active-task
idle_active_field 200
unauth_upload_cancel_status 401
upload_cancel 200 {'ok': True, 'status': 'canceled', 'upload_attempt_id': 'attempt-1'}
late_upload_rejected 409 {'error': 'Upload attempt canceled', 'ok': False, 'status': 'canceled', 'upload_attempt_id': 'attempt-1'}
late_upload_not_queued True
normal_with_attempt 200 queued True attempt-2
normal_task_store_attempt attempt-2
normal_no_attempt 200 queued True True
```

## Risks / Follow-up

- Upload-attempt cancellation is keyed by the frontend-generated id; the frontend must generate a unique id per upload attempt and send the same id to both `/api/upload-cancel...` and `/api/process`.
- Canceled upload attempt ids are kept in memory and expire after `TASK_TTL`, matching the existing in-memory task model. A backend restart clears them.
- If a request is canceled client-side before it ever reaches the backend, the upload-cancel endpoint records the attempt id so a late arrival can be dropped.

## Notes For Next Agent

- Frontend should call `POST /api/upload-cancel/<upload_attempt_id>` when a `wx.uploadFile` attempt times out or is interrupted before a backend `task_id` exists.
- Frontend should use `active_task_id` or `processing_task_id` from status responses to decide whether the current task is actively processing or waiting behind another task.
