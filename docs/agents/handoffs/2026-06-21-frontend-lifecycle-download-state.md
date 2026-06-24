# Handoff

## From

Agent role: Frontend

## Task ID

STATE-FE-001

## Summary

Stopped scanner foreground lifecycle from re-verifying tokens and added per-result album-save tracking so New Task preserves unsaved or failed source groups.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: `onShow` now only updates the scanner tab state and checks whether a local token exists; it no longer calls `/api/auth/verify` or mutates scanner state on normal foreground return.
  - change: Result objects now carry `saveStatus` values: `unknown`, `saving`, `saved`, or `failed`.
  - change: Single-result save and all-download flows update per-result save state and surface partial all-download failures in the persistent status bar.
  - change: `新任务` now preserves source images and extracted results for any source group with failed, unknown, saving, or otherwise unsaved results, and clears only source groups whose extracted results all saved successfully.
  - change: Completed-state manual source-image delete now removes exactly the current source image and that source's extracted results, then reindexes remaining source-image references.
- `docs/agents/handoffs/2026-06-21-frontend-lifecycle-download-state.md`
  - change: Added this handoff.

## Behavior Changed

Returning from background or switching back to the scanner tab no longer re-verifies a stored token from `pages/index/index.js`, so selected images, extracted results, failed source markers, current preview, and completed status/actions are not wiped by a transient auth verification failure. Missing local token still redirects to `/pages/auth/auth`, and settings manual token clear remains the way to leave the authenticated scanner flow.

Album save state is now tracked per extracted result. Downloading to a temporary file via `localPath` is not treated as saved to album. If all-download has any failed save/download, the status bar remains visible with a partial-failure message such as:

```text
保存完成，成功 1 张，失败 1 张
```

When tapping `新任务`, source groups are removed only if all extracted polaroids for that source have `saveStatus=saved` and the source image is not otherwise marked failed. Unsaved, failed, unknown, or saving source groups remain with their extracted results.

Manual deletion from the selected source image preview after processing is separate from `新任务`: it deletes the current source image and that source's extracted results regardless of save state, while preserving the other source images, result groups, save states, failed markers, completed actions, and remapped source indexes.

## API Contract Changes

None. This is Frontend-only lifecycle and album-save state. Existing `/api/process`, `/api/status/<task_id>`, `/api/result/<task_id>/<result_id>`, `/api/upload-cancel/<upload_attempt_id>`, `/api/cancel/<task_id>`, `postprocess_mode`, `polaroid_size`, picker behavior, auth storage keys, custom tab bar, calendar route, and `izaya7-map` route remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\izaya7-map\izaya7-map.js
node - <mock script>
git diff --check
```

Results:

```text
node --check passed for recommended files.
Mock checks passed: foreground return without token reverify, missing-token redirect, scanner state preservation, all-download save/failed state tracking, visible partial failure status, single-result save failure tracking, New Task preserving unsaved/failed/unknown result groups, failed-source-only retry preservation, and completed-state manual source-image delete/reindexing.
git diff --check passed.
```

## Risks / Follow-up

- Real-device QA should confirm backgrounding during album save produces the partial-failure status and leaves the affected source group available after `新任务`.
- The old `verifyCachedToken` helper is left in place but is no longer called by scanner `onShow`; future cleanup can remove it if no other flow needs it.

## Notes For Next Agent

- Treat `localPath` as a temporary download cache only. Album-save completion is represented by `saveStatus=saved`.
- The New Task preservation decision is source-group based and uses `sourceImageIndex`, so retained results are remapped when saved source groups are removed.
