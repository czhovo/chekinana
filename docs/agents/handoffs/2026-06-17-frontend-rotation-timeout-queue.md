# Handoff

## From

Agent role: Frontend

## Task ID

BATCH-FE-010

## Summary

Fixed rotated-preview fallback/stale handling, upload timeout/retry limits, queued copy, final shortage status, and completed-processing actions.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added bounded rotated-preview generation with timeout fallback and stale callback guards.
  - change: Set upload timeout to 15 seconds and timeout retries to 2 retries per upload attempt.
  - change: Removed queue-position text from queued/waiting status while preserving active-task processing status.
  - change: Report final insufficient polaroid counts for single-image and batch completion while preserving partial results.
  - change: Added all-result download and clear-successful-source-image actions, preserving failed source images.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Replaced completed-result toolbar actions with `全部下载` and `删除全部图片`; disabled all-download when no extracted results exist.
- `wechat-miniprogram/pages/index/index.wxss`
  - change: Added danger styling for the completed-result delete action.
- `docs/agents/handoffs/2026-06-17-frontend-rotation-timeout-queue.md`
  - change: Added this handoff.

## Behavior Changed

Rotated preview generation now falls back to the original selected image if image info/canvas export fails or the fallback timer fires, while preserving the per-image `rotation_degrees` upload value. Late rotation callbacks are ignored when a newer image or rotation state supersedes them.

Upload timeout handling now starts retry/cancel handling after 15 seconds per attempt and stops after 2 timeout retries. Queued/waiting status no longer displays queue position, but active current-task processing/extracting status is still shown.

When completed single or batch results contain fewer extracted polaroids than the expected count, the final status includes received/expected counts and keeps partial successful results visible. After processing completes, the normal add/start actions are replaced by `全部下载` and `删除全部图片`; clearing removes successfully processed source images while keeping failed source images for inspection or retry.

## API Contract Changes

None.

Existing `/api/process`, `/api/status/<task_id>`, `/api/result/<task_id>/<result_id>`, `/api/cancel/<task_id>`, and `/api/upload-cancel/<upload_attempt_id>` usage remains unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
git diff --check
node - mocked BATCH-FE-010 behavior checks
```

Results:

```text
node --check passed.
git diff --check passed.
Mocked checks passed:
- rotation success updates large preview and thumbnail from the rotated export
- rotation image-info failure falls back to original image and keeps rotation_degrees
- rotation timeout fallback is bounded at 3000ms
- stale rotation export callback is ignored
- thumbnail fallback remains visible
- upload timeout constant is 15000ms
- upload timeout retry cap is 2 retries, producing 3 total timed-out attempts
- queued text omits queue position
- active-task processing/extracting status is still shown
- final insufficient-count status includes received/expected counts for single and batch
- all-download saves every extracted result
- clear-successful-images removes successful source images
- failed source image is preserved with its rotation state
```

## Risks / Follow-up

- Full WeChat DevTools visual verification was not available in this agent environment.
- Reviewer should re-check on device/DevTools that WXML conditional toolbar behavior matches WeChat runtime expectations.

## Notes For Next Agent

- PM taskboard commit `e9d4f38` was imported with `git cherry-pick` and resolved in favor of the PM taskboard version, producing local docs commit `cb34891`.
- Scope is limited to `BATCH-FE-010`; Backend APIs, auth/token flow, RunPod startup, contact UI, result APIs, batch ordering, per-image counts, interrupt behavior, pre-task upload cancel endpoint, and incremental result display were left unchanged.
