# Handoff

## From

Agent role: Frontend

## Task ID

BATCH-FE-011

## Summary

Fixed final insufficient-count status so user-entered expected counts are not hidden by Backend actual completion counts.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added `getExpectedPolaroidTarget(payload, fallbackExpectedCount)` to prioritize user-entered expected count, then `payload.requested_polaroids`, then Backend actual/finalized count fields.
  - change: Updated single-image direct completion, single-image polling completion, batch direct completion, and batch polling completion to use the preserved expected target.
- `docs/agents/handoffs/2026-06-18-frontend-shortage-status.md`
  - change: Added this handoff.

## Behavior Changed

If the user enters an expected count of 5 and Backend completes with actual count fields such as `total_polaroids: 3` and `expected_polaroids: 3`, the final status now reports `结果不足：已收到 3/5 张` while keeping all 3 extracted results visible.

The same target-count priority applies per image in batch processing, so a batch image with 3 received out of 5 expected contributes the shortage to the final batch status and preserves the failed source image index for retry/inspection.

## API Contract Changes

None.

No Backend APIs, auth/token behavior, upload timeout/retry, rotation preview behavior, queue copy, completed-batch actions, result APIs, contact UI, interrupt/cancel behavior, or incremental result display were changed.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
git diff --check
node - mocked BATCH-FE-011 shortage target checks
```

Results:

```text
node --check passed.
git diff --check passed.
Mocked checks passed:
- single-image user expected 5 / Backend actual 3 shows final 3/5 shortage and preserves 3 results
- single-image requested_polaroids 5 / Backend actual 3 shows final 3/5 shortage and preserves 3 results
- batch image user expected 5 / Backend actual 3 returns shortage 3/5 and preserves 3 results
- final batch status includes 3/5 shortage and preserves the failed source image index
- Backend actual count fields remain a fallback when no user-entered or requested target exists
```

## Risks / Follow-up

- Full WeChat DevTools/device verification was not available in this agent environment.
- Reviewer should re-run the P1 scenario from commit `1873ae9`: user expected 5, Backend completion actual fields 3, and 3 result images.

## Notes For Next Agent

- PM taskboard commit `080150a` was imported with `git cherry-pick`, producing local docs commit `6897acb`.
- Scope is limited to BATCH-FE-011 shortage status target selection.
