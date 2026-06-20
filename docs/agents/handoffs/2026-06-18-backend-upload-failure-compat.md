# Handoff

## From

Agent role: Backend

## Task ID

BATCH-BE-004

## Summary

Audited the backend upload/status/result/cancel contracts for the post-size batch regressions and found no backend code change is required.

## Files Changed

- `docs/agents/handoffs/2026-06-18-backend-upload-failure-compat.md`
  - change: records the Backend compatibility audit and smoke verification for `BATCH-BE-004`.

## Behavior Changed

None.

The screenshot error `uploadFile:fail Error: Client network socket disconnected before secure TLS connection was established` can occur before Flask receives an HTTP request. It is a client/network/TLS-handshake failure from the mini-program upload path, so Backend cannot return a task response for that failure mode. The Frontend fix should treat it like the existing bounded upload failure path: retry up to the agreed limit, abort/cancel the upload attempt when possible, and avoid stale late-callback mutation.

Existing Backend contracts still support that Frontend behavior:

- `POST /api/process` remains the single-image upload/task creation endpoint.
- `POST /api/upload-cancel/<upload_attempt_id>` records a pre-task upload attempt as canceled.
- A late `/api/process` request with a pre-canceled `upload_attempt_id` returns `409` with `status: "canceled"` and does not queue extraction.
- `GET /api/status/<task_id>` still exposes `active_task_id`, `processing_task_id`, queue/status fields, `results`, `expected_polaroids`, `total_polaroids`, `warning`, and `extraction_complete`.
- `GET /api/result/<task_id>/<result_id>` and `GET /api/result/<task_id>` still serve generated result images.
- `POST /api/cancel/<task_id>` still cancels queued/processing tasks after a `task_id` exists.

## API Contract Changes

None.

No Backend response shape, request shape, auth behavior, RunPod startup behavior, result route, contact route, mini/wide/auto geometry, or extraction internals were changed.

## Verification

Commands run:

```text
git cherry-pick 13c6f87
python -m py_compile backend\app.py
git diff --check
Focused Flask compatibility smoke with mocked torch/flask_cors/scipy.spatial:
  - unauthenticated upload cancel is rejected
  - protected upload cancel records an upload attempt id
  - late /api/process for a pre-canceled upload attempt returns 409 canceled and is not queued
  - normal /api/process still queues and preserves upload_attempt_id, expected count, and polaroid_size
  - /api/status/<task_id> exposes active_task_id and processing_task_id for queued task visibility
  - /api/result/<task_id>/<result_id> serves an existing result image
  - /api/result/<task_id> serves the final result image
  - missing result id returns 202
  - /api/cancel/<task_id> cancels a queued task, removes it from the queue, and status reports canceled
```

Results:

```text
py_compile: passed
git diff --check: passed
backend compatibility smoke passed
late_upload 409 {'error': 'Upload attempt canceled', 'ok': False, 'status': 'canceled', 'upload_attempt_id': 'smoke-attempt-1'}
normal_process 200 {'status': 'queued', 'requested_polaroids': 3, 'expected_polaroids': 3, 'upload_attempt_id': 'smoke-attempt-2'}
status_fields {'status': 'queued', 'queue_position': 1, 'active_task_id': 'active-smoke-task', 'processing_task_id': 'active-smoke-task', 'results_count': 0, 'extraction_complete': False}
result_routes 200 200 202
cancel_task 200 {'ok': True, 'previous_status': 'queued', 'queue_removed': True, 'status': 'canceled', 'task_id': '<smoke-task-id>'}
```

## Risks / Follow-up

- No backend can reject a request that never reaches it; Frontend must handle the TLS/socket failure locally and call `/api/upload-cancel/<upload_attempt_id>` for the attempt id it generated.
- The canceled upload attempt registry remains in-memory and expires with `TASK_TTL`, matching the existing task model from `BATCH-BE-003`.

## Notes For Next Agent

- Frontend should not display the raw low-level TLS/socket error in the status bar; it should route it through the bounded upload failure status.
- Reviewer should verify this handoff alongside the Frontend fix for multiple shortage aggregation, post-completion navigation preserving results, `新任务` copy, failed-source preservation, and all-download behavior.
