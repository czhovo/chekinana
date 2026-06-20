# Handoff

## From

Agent role: Backend

## Task ID

BATCH-BE-002

## Summary

Added protected task cancellation for the existing backend task model so the frontend interrupt button can cancel the active extraction task.

## Files Changed

- `backend/app.py`
  - change: added `POST /api/cancel/<task_id>`, cancel state helpers, queued-task queue removal, processing-task cancel flags, safe cancellation checkpoints in extraction, canceled-task worker guards, canceled-task TTL cleanup, and intermediate-result suppression after cancellation.
- `docs/agents/handoffs/2026-06-17-backend-task-cancel.md`
  - change: records Backend implementation and verification notes for `BATCH-BE-002`.

## Behavior Changed

`POST /api/cancel/<task_id>` is now available as a protected `/api/*` endpoint, so existing token auth applies. It is not added to the `/api/process` and `/api/contact` POST rate-limit bucket.

Queued task behavior:

- The task is removed from `task_queue`.
- The task is marked `status: "canceled"` and `phase: "canceled"`.
- `cancel_requested` is set to `true`.
- `raw_data` is removed immediately.
- `/api/status/<task_id>` returns `status: "canceled"`.

Processing task behavior:

- The task is marked `status: "canceled"` and `phase: "canceled"`.
- `cancel_requested` is set to `true`.
- Extraction checks cancel state before loading, before detection, after detection, before extraction, before each polaroid, before adding each result, and before final done state.
- Already produced results remain in `results` and stay downloadable through the existing result endpoints until normal TTL cleanup.
- After cancellation, `add_intermediate()` skips adding more results for the task.

Terminal tasks:

- Canceling a missing task returns 404.
- Canceling a `done` or `failed` task returns 409 and leaves it unchanged.

## API Contract Changes

Added protected endpoint:

```text
POST /api/cancel/<task_id>
```

Successful queued/processing cancellation response:

```json
{
  "ok": true,
  "task_id": "...",
  "status": "canceled",
  "previous_status": "queued|processing|...",
  "queue_removed": true
}
```

Existing `/api/process`, `/api/status/<task_id>`, `/api/result/<task_id>/<result_id>`, auth, RunPod startup, and normal processing response shapes remain compatible.

## Verification

Commands run:

```text
git cherry-pick d721880
python -m py_compile backend\app.py
git diff --check
Taskboard hash check: git show HEAD:docs/agents/taskboard.md | git hash-object --stdin; git show d721880:docs/agents/taskboard.md | git hash-object --stdin
Focused Flask cancel-route smoke with mocked torch/flask_cors/scipy.spatial:
  - unauthorized cancel
  - queued cancel
  - status route after queued cancel
  - processing cancel
  - status route after processing cancel
  - add_intermediate after cancel
  - missing-task cancel
  - result downloads after cancel for already produced result
```

Results:

```text
py_compile: passed
git diff --check: passed
taskboard hash: 67b18e8841fb7dafd9d4ed81a886a80035fec4b6 == 67b18e8841fb7dafd9d4ed81a886a80035fec4b6
unauthorized_status 401
queued_status_before_auth queued
queued_cancel 200 {'ok': True, 'previous_status': 'queued', 'queue_removed': True, 'status': 'canceled', 'task_id': 'queued-task'}
queued_removed_from_queue True
queued_raw_removed True
queued_status_route 200 canceled True
processing_cancel 200 {'ok': True, 'previous_status': 'processing', 'queue_removed': False, 'status': 'canceled', 'task_id': 'processing-task'}
processing_store canceled True True
processing_status_route 200 canceled 1
canceled_add_intermediate_skipped 1 1
missing_cancel_status 404
part_result_after_cancel 200 image/png
legacy_result_after_cancel 200 image/png
```

## Risks / Follow-up

- Cancellation is cooperative. If a processing task is inside a long SAM/model call, cancellation is reflected in status immediately, and the worker stops at the next safe checkpoint.
- The backend cannot preempt a currently running CPU/GPU operation mid-call without a larger worker/process redesign, which is outside this task.
- Existing produced results remain downloadable for canceled tasks, matching the taskboard requirement.

## Notes For Next Agent

- Frontend should call `POST /api/cancel/<task_id>` for the currently active backend task when the user interrupts.
- Frontend should treat `status: "canceled"` from `/api/status/<task_id>` as the interrupted terminal state for that task.
