# Handoff

## From

Agent role: Frontend

## Task ID

RESULTDL-FE-001

## Summary

Preserved immediate result visibility while making eager result downloads bounded and retained, raised upload retries to 3, and added the 50-polaroid guidance line in the empty preview state.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: `UPLOAD_MAX_RETRIES` is now `3`.
  - change: Extracted results now carry a `downloadStatus` in addition to `saveStatus`.
  - change: Result prefetch now immediately enqueues every returned result, displays the result from the backend URL right away, and downloads retained completed-size images through a bounded eager queue with 3 active downloads.
  - change: Downloaded `localPath` and `downloadStatus` are preserved when polling or incremental updates return a duplicate result record.
  - change: Result download/save failures also update the persistent status bar so late result taps do not fail silently.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Empty preview helper adds the exact second line `单次处理的拍立得数量不应超过50张`.
  - change: Result images render `localPath || url`, so returned results are visible immediately and switch to the retained local file after download.
- `wechat-miniprogram/pages/index/index.wxss`
  - change: Added styling for the second empty-preview helper line.
- `docs/agents/handoffs/2026-06-21-frontend-large-result-downloads.md`
  - change: Added this handoff.

## Behavior Changed

Every backend-returned extracted polaroid remains in frontend state as soon as it is received and is displayed immediately in the result area. The frontend no longer launches an unbounded number of `wx.downloadFile` calls; instead it eagerly queues all returned results and runs a small number of active downloads at a time. This avoids the high-count resource exhaustion path while keeping the product behavior immediate and retained.

Completed-size downloaded images are not lazily fetched, LRU-evicted, or discarded by policy while the mini program remains open. They remain in `extractedImages` as `localPath` values until the mini program exits or the user explicitly deletes them through existing New Task cleanup or source-image deletion behavior.

All-download, single-result save, per-result save state, completed navigation, batch ordering, source grouping, picker behavior, auth behavior, upload/process/status/cancel contracts, `postprocess_mode`, `polaroid_size`, and main-sync routes are preserved.

## API Contract Changes

None. This is a Frontend-only reliability change. Existing `/api/process`, `/api/status/<task_id>`, `/api/result/<task_id>/<result_id>`, `/api/upload-cancel/<upload_attempt_id>`, `/api/cancel/<task_id>`, auth headers, `postprocess_mode`, and `polaroid_size` request fields remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\izaya7-map\izaya7-map.js
node - <RESULTDL mock script>
git diff --check
```

Mock checks covered:

```text
45 returned results stay visible immediately.
Only 3 result downloads are active while the rest are queued.
Queued downloads drain without evicting any retained result.
Downloaded localPath and downloadStatus survive duplicate result merges.
Late single-result tap download failure sets persistent error status.
Upload failure retry path performs initial upload plus 3 retries.
The empty-preview 50-polaroid helper and localPath-first result rendering are present.
```

## Risks / Follow-up

- Real-device QA should still confirm a 40+ result run on WeChat after Backend reduces completed output width to 1200, because the original failure depended on the device runtime and resource pressure.
- The download queue intentionally limits simultaneous downloads. This means all results are scheduled immediately and displayed immediately, while actual local-file completion is paced to keep the mini program usable for later result taps and new uploads.
