# Handoff

## From

Agent role: Frontend

## Task ID

SAVE-FE-001

## Summary

Made result local-download and album-write state visible and routed single/all save actions through bounded retry paths.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added durable result-state decoration, bounded remote-download and album-save helpers, all-download failure-skip behavior, and single-result save reuse of the same save path.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Added a top-right result-card status badge.
- `wechat-miniprogram/pages/index/index.wxss`
  - change: Styled yellow remote-only, green downloaded, and green album-written badge states.
- `docs/agents/handoffs/2026-06-23-frontend-result-save-state.md`
  - change: Added this handoff.

## Behavior Changed

Each result card now shows a top-right badge:

- yellow circle: result is visible but not downloaded to the mini program.
- green circle: result has a local mini-program file path but has not been written to the user's album.
- green check: `wx.saveImageToPhotosAlbum` has succeeded for that result.

Manual single-result save and `全部下载` now share the same bounded save path. Remote result downloads and album writes each have a timeout plus one retry. If a result still fails or times out, that result remains not album-written, the UI records failure, and all-download continues with later results before showing a partial-failure summary.

Album-write success is durable. Later status merges, background predownload completion, or stale failure patches do not downgrade a result already marked as saved to album. If an unabortable album-save call times out but later returns success, the result is still marked album-written.

`新任务` keeps using album-write state only: groups are preserved when any result is not `saved`, and groups whose results are all album-written still clear through the existing local-cache cleanup path from `CACHE-FE-001`.

## API Contract Changes

None. This is Frontend-only. Auth, picker, upload/process/status/result, cancel/upload-cancel, `postprocess_mode`, `polaroid_size`, result ordering, immediate display, 3-active background predownload, local-cache cleanup, and failed-download non-requeue behavior remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram/pages/index/index.js
node - <SAVE-FE-001 save-state mock>
node - <SAVE-FE-001 saved-state durability mock>
git diff --check
```

Results:

```text
node --check: passed
save-state mock: passed
saved-state durability mock: passed
git diff --check: passed
```

Mock checks covered:

```text
remote-only result maps to yellow/remote badge state.
local downloaded result maps to green/downloaded badge state.
album-written result maps to green-check/album badge state.
mergeImages preserves saved album state and album badge.
single-result save retries a failed remote download once, records localPath, retries album save once, and records album success.
all-download marks a failed item not album-written, skips it, continues later results, releases loading, and reports partial failure.
saved album state is not downgraded by later failed save or failed download patches.
```

## Risks / Follow-up

- Real-device QA should confirm the 15-second timeout feels right for slow WeChat album writes and remote result downloads.
- Since `wx.saveImageToPhotosAlbum` cannot be aborted, a timed-out save may later succeed; the implementation records that late success if WeChat reports it.

## Notes For Next Agent

- Reviewer should verify badge visuals on device/emulator and confirm `新任务` still clears only album-written groups while preserving unsaved/failed groups.
