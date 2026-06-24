# Handoff

## From

Agent role: Frontend

## Task ID

RESULTDL-FE-002

## Summary

Fixed the Reviewer P1 where an eager result download that had already exhausted its retry budget could be requeued by later status refreshes or passive prefetch calls.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Passive eager result prefetch now skips results whose `downloadStatus` is already `failed`.
- `docs/agents/handoffs/2026-06-21-frontend-result-download-requeue.md`
  - change: Added this handoff.

## Behavior Changed

If a result exhausts the eager download retry budget and is marked `downloadStatus=failed`, later duplicate status merges preserve that failed state and passive `prefetchResultImages(...)` calls do not enqueue the same result again with a fresh eager retry budget.

Explicit user intent remains preserved. If the user taps a failed result, the existing manual save/download path still attempts to download that result for saving.

## API Contract Changes

None. This is Frontend-only. Existing result routes, auth headers, upload/process/status/cancel behavior, `postprocess_mode`, `polaroid_size`, picker behavior, New Task cleanup, source-image deletion, immediate result display, 3 active eager downloads, retained `localPath` state, upload max retries of 3, and the 50-polaroid helper line remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\izaya7-map\izaya7-map.js
node - <RESULTDL-FE-002 requeue mock>
node - <RESULTDL-FE-001 positive mock>
git diff --check
```

Mock checks covered:

```text
An initial eager result download starts.
The built-in eager retry starts once after the first failure completes.
The second eager failure marks the result as downloadStatus=failed.
A duplicate status result preserves failed status through mergeImages(...).
A later passive prefetchResultImages(...) call schedules no extra download and leaves the eager queue empty.
Manual tapping the failed result still starts the explicit download/save path.
The prior positive high-count behavior remains: 45 results stay visible immediately, only 3 active downloads run, queued downloads drain, retained localPath state is preserved, upload max retries remain 3, and the helper/localPath-first rendering remain present.
```

## Risks / Follow-up

- Real-device QA should re-run the high-count failure case and confirm that a persistently failed high-index result does not keep consuming download slots during later status refreshes.
