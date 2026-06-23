# Handoff

## From

Agent role: Frontend

## Task ID

SAVE-FE-002

## Summary

Preserved downloaded and album-written result state across extraction refreshes and stale batch arrays.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added latest-state-preserving result merges and routed batch/single refresh paths through them.
- `docs/agents/handoffs/2026-06-23-frontend-save-state-refresh.md`
  - change: Added this handoff.

## Behavior Changed

Receiving new extracted results or status refreshes no longer downgrades existing result badges from green downloaded or green-check album-written back to yellow remote-only.

Album-written state remains an irreversible local truth for the active result set. Status polling, newly received results, batch progress updates, batch completion, interrupt preservation, and background predownload callbacks may add new results or upgrade local download state, but they do not downgrade `saveStatus=saved` or remove known `localPath` values.

Batch paths that use closure-held `baseImages`, `collectedImages`, or accumulated arrays now re-merge with the latest `this.data.extractedImages` before writing visible results. This preserves source-image indexes and ordering while carrying forward local download and album-write state.

`新任务` still uses album-write truth to decide cleanup, and cleared saved groups still go through the existing local-cache cleanup behavior from `CACHE-FE-001`.

## API Contract Changes

None. This is Frontend-only. Backend result routes/status payloads, auth, picker, upload/process/status/cancel contracts, postprocessing, polaroid size, immediate display, 3-active background predownload, failed-download non-requeue, single-result save, and all-download timeout/retry/failure-skip behavior remain unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram/pages/index/index.js
node - <SAVE-FE-002 save refresh durability mock>
git diff --check
```

Results:

```text
node --check: passed
save refresh durability mock: passed
git diff --check: passed
```

Mock checks covered:

```text
Single-image refresh keeps album-written state and green-check badge while adding a new result.
Batch stale base arrays keep known localPath and green downloaded badge.
finishBatchExtract preserves album-written state through stale accumulated arrays.
Background predownload after album save does not downgrade green-check album state.
新任务 after refresh preserves unsaved groups, clears album-written groups, and still cleans local files for cleared groups.
```

## Risks / Follow-up

- Real-device QA should repeat the reported incremental extraction case and confirm green downloaded/green-check badges no longer flash back to yellow as new results arrive.

## Notes For Next Agent

- Reviewer should focus on stale-array paths and direct `extractedImages` writes, especially batch polling and finish paths.
