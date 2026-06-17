# Handoff

## From

Agent role: Frontend

## Task ID

BATCH-FE-010

## Summary

Fixed rotated-preview fallback/stale handling, upload timeout/retry limits, queued copy, final shortage status, and completed-processing actions.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Removed rotated-preview canvas export after real WeChat testing showed exported temp images could become stretched, cropped, or single-color.
  - change: Kept preview and thumbnails on the original image path and moved rotation to per-image display state.
  - change: Added keyed per-image `currentPreviewImages` state so switching between differently rotated images recreates the preview image node instead of briefly reusing the previous image rotation.
  - change: Set upload timeout to 15 seconds and timeout retries to 2 retries per upload attempt.
  - change: Removed queue-position text from queued/waiting status while preserving active-task processing status.
  - change: Report final insufficient polaroid counts for single-image and batch completion while preserving partial results.
  - change: Added all-result download and clear-successful-source-image actions, preserving failed source images.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Rendered preview and thumbnails from original image paths with per-image rotation classes.
  - change: Rendered the large preview through keyed `currentPreviewImages` instead of a single reused image node bound to global `rotationDegrees`.
  - change: Replaced completed-result toolbar actions with `全部下载` and `删除全部图片`; disabled all-download when no extracted results exist.
- `wechat-miniprogram/pages/index/index.wxss`
  - change: Added CSS rotation rules for the large preview and thumbnail strip.
  - change: Added danger styling for the completed-result delete action.
- `docs/agents/handoffs/2026-06-17-frontend-rotation-timeout-queue.md`
  - change: Added this handoff.

## Behavior Changed

Rotated preview display no longer generates a temporary rotated image through canvas export. The mini-program keeps the original selected image path visible and applies the current per-image rotation as UI display state, while preserving the per-image `rotation_degrees` upload value. This avoids the real-WeChat failure mode where canvas-exported temp images can render stretched, cropped, or as a single-color block.

The large preview now renders from a single-item keyed preview list. The key includes the image id, preview path, and preview rotation, so switching between images with different rotations forces WeChat to rebuild the preview image node rather than momentarily applying the previous image's rotation to the next image.

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
node - mocked real-WeChat rotation regression checks
node - mocked keyed per-image preview switching checks
```

Results:

```text
node --check passed.
git diff --check passed.
Mocked checks passed:
- rotation updates large preview and thumbnail from the original image path plus per-image rotation class
- rotation updates large preview and thumbnail by per-image display state without canvas export
- original image path remains visible after rotation and keeps rotation_degrees
- stale canvas/export callbacks cannot occur because preview no longer uses canvas export
- thumbnail remains visible from the same original source path
- upload timeout constant is 15000ms
- upload timeout retry cap is 2 retries, producing 3 total timed-out attempts
- queued text omits queue position
- active-task processing/extracting status is still shown
- final insufficient-count status includes received/expected counts for single and batch
- all-download saves every extracted result
- clear-successful-images removes successful source images
- failed source image is preserved with its rotation state
- real-WeChat rotation regression mock keeps original image paths for large preview and thumbnails
- real-WeChat rotation regression mock confirms preview rotation no longer calls image info, canvas, or canvas export APIs
- real-WeChat rotation regression mock confirms switching selected images keeps per-image path/rotation state
- real-WeChat rotation regression mock confirms upload still sends rotation_degrees
- keyed preview switching mock confirms switching images with different rotations creates distinct previewKey values
- keyed preview switching mock confirms rotating the current image creates a new previewKey
- keyed preview switching mock confirms large preview no longer binds directly to global rotationDegrees
```

## Risks / Follow-up

- Full WeChat DevTools visual verification was not available in this agent environment.
- Reviewer should re-check on device/DevTools that WXML conditional toolbar behavior matches WeChat runtime expectations.

## Notes For Next Agent

- PM taskboard commit `e9d4f38` was imported with `git cherry-pick` and resolved in favor of the PM taskboard version, producing local docs commit `cb34891`.
- Scope is limited to `BATCH-FE-010`; Backend APIs, auth/token flow, RunPod startup, contact UI, result APIs, batch ordering, per-image counts, interrupt behavior, pre-task upload cancel endpoint, and incremental result display were left unchanged.
