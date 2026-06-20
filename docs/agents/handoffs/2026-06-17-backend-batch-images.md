# Handoff

## From

Agent role: Backend

## Task ID

BATCH-BE-001

## Summary

Audited and verified that the existing single-image backend task API supports V1 sequential batch orchestration without adding a batch route or changing backend behavior.

## Files Changed

- `docs/agents/handoffs/2026-06-17-backend-batch-images.md`
  - change: records Backend audit findings and verification evidence for `BATCH-BE-001`.

## Behavior Changed

None.

The existing backend API already supports the V1 frontend batch plan:

- `POST /api/process` creates one independent `task_id` per image.
- `/api/status/<task_id>` returns task-local metadata and result list.
- `/api/result/<task_id>/<result_id>` returns one task-local result image.
- The backend result order within an image remains the existing task result order.
- The frontend can make result keys unique across tasks with `taskId:resultId`.

No new batch route was added.

## API Contract Changes

None.

Existing request fields remain honored per single-image submission:

- `token`
- `wb`
- `denoise`
- `rotation_degrees`
- `expected_polaroids`
- `polaroid_count`

Existing response shapes remain unchanged.

## Verification

Commands run:

```text
git cherry-pick 49157b8
python -m py_compile backend\app.py
git diff --check
Focused Flask smoke with mocked torch/flask_cors/scipy.spatial and UTF-8 output:
  - submit 9 images sequentially to POST /api/process
  - verify 9 independent task ids and queue entries
  - verify per-image expected_polaroids, rotation_degrees, wb, and denoise are stored per task
  - verify /api/status/<task_id> works
  - verify /api/result/<task_id>/<result_id> works with a task-local result
  - verify 10th process request is still allowed by rate_limit_per_minute=10
  - verify 11th process request returns 429
  - verify status/result still work after process rate limit is reached
```

Results:

```text
py_compile: passed
git diff --check: passed
nine_submit_statuses [200, 200, 200, 200, 200, 200, 200, 200, 200]
unique_task_ids 9
queue_length_after_nine 9
first_fields 1 1 90 False False
ninth_fields 9 9 90 False True
status_status 200 True 0
result_status 200 image/png
tenth_status 200
eleventh_status 429
status_after_limit 200
result_after_limit 200
```

## Risks / Follow-up

- Full SAM extraction was not run locally because this Windows environment has known heavyweight dependency issues; the smoke intentionally mocked unrelated model/scipy imports and validated the Flask contract surface required for V1 batch orchestration.
- `rate_limit_per_minute` is currently `10`, so a normal max-9 image batch is inside the backend submission budget. Other POSTs that share the same rate bucket immediately before a batch could still consume part of that budget; the taskboard's normal 9-image batch case is covered.

## Notes For Next Agent

- Frontend should keep V1 as sequential single-image submissions and should not require a new backend batch endpoint.
- Status polling and result downloads are not process-rate-limited and remain safe during a sequential batch.
