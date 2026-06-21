# Handoff

## From

Agent role: Frontend

## Task ID

CACHE-FE-001

## Summary

Deleted mini-program local source/result files best-effort when source-image groups are explicitly removed.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added source/result local-file cleanup helpers, wired cleanup into pre-processing source deletion, completed-state source deletion, and `新任务` cleanup, and dropped queued download references for removed results.
- `docs/agents/handoffs/2026-06-21-frontend-local-cache-cleanup.md`
  - change: Added this handoff.

## Behavior Changed

When `新任务` clears a source-image group whose results were all saved, the mini program immediately attempts to delete that selected source file and every downloaded local result file for that source. Source groups preserved by the existing unsaved/failed/unknown save-state rules are not deleted.

When the user manually deletes a source image after processing, only that source image and its extracted result local files are deleted, while remaining source images/results are preserved and reindexed.

When the user deletes a selected source image before processing, that source image path is deleted from the mini-program local file cache.

Cleanup is best-effort: individual delete failures are logged and do not block UI reset. Remote backend result URLs are skipped; saved photos in the user's album are not removed. Removed results are also dropped from pending download tracking, and stale download callbacks must still match the current result key and URL before updating state.

## API Contract Changes

None. This is Frontend-only. Auth, picker, upload/process/status/result routes, immediate result display, 3-active eager download concurrency, `RESULTDL-FE-002` failed-download non-requeue behavior, `postprocess_mode`, and `polaroid_size` remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram/pages/index/index.js
node - <CACHE-FE-001 local cleanup mock>
git diff --check
```

Results:

```text
node --check: passed
local cache cleanup mock: passed
git diff --check: passed
```

Mock checks covered:

```text
新任务 deletes the cleared saved source group source path and result localPath.
新任务 preserves unsaved source groups and reindexes preserved results.
新任务 drops queued download references for removed results.
Completed-state manual source deletion deletes only that source path/preview path and result wxfile:// URL.
Completed-state manual source deletion preserves and reindexes other source groups.
Pre-processing source deletion deletes the selected source path and preserves other selected sources.
```

## Risks / Follow-up

- Real-device QA should confirm WeChat accepts `FileSystemManager.unlink` for the selected temp-file paths returned by `wx.chooseImage`; the fallback remains best-effort through `wx.removeSavedFile`.

## Notes For Next Agent

- Reviewer should verify the cleanup remains scoped to explicit source-image removal and does not reintroduce lazy result display, LRU cleanup, or automatic deletion while completed results are still visible.
