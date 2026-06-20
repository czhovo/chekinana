# Handoff

## From

Agent role: Reviewer

## Task ID

RESULTDL-REV-001

## Findings

- P1 BLOCKING `wechat-miniprogram/pages/index/index.js:1337`
  Failed eager result downloads are re-queued on later status/prefetch passes. `handleResultDownloadFailure` marks a result as `downloadStatus=failed` after the bounded retry budget is exhausted, and `mergeImages` correctly preserves that failed status across duplicate backend status results. But `enqueueResultDownload` only skips missing URLs, existing `localPath`, `wxfile://`, active downloads, and queued downloads; it does not skip `downloadStatus=failed`. On the next `prefetchResultImages(merged)` call, the same permanently failed high-index result is queued again with a fresh retry budget. A targeted mock reproduced the issue: the first failed result attempted original plus one retry, then after a duplicate status merge and prefetch, it attempted two more downloads (`calls.downloads.length` became `4` instead of staying `2`). This can recreate the high-count resource exhaustion that RESULTDL is meant to fix, because a bad result around 40+ can be retried on every poll/status refresh and continue consuming download slots while later result taps or new uploads are expected to remain usable.
  Owner: Frontend

## Open Questions

- None.

## Verification

Reviewed commits:

```text
dcba050 pm: require 1200 result output and immediate retention
86ea23a frontend: retain immediate result downloads
6717034 Reduce polaroid result output size
```

Local cherry-picks:

```text
ff64f9b frontend: retain immediate result downloads
545a646 Reduce polaroid result output size
```

Commands run:

```text
node --check wechat-miniprogram/pages/index/index.js
node --check wechat-miniprogram/pages/auth/auth.js
node --check wechat-miniprogram/pages/izaya7-map/izaya7-map.js
python -m py_compile backend/app.py scripts/check_polaroid_size.py scripts/check_postprocessing_modes.py scripts/check_large_result_routes.py
git diff --check dcba050..HEAD
git diff --check
python scripts/check_polaroid_size.py
python scripts/check_large_result_routes.py
python scripts/check_postprocessing_modes.py
node - <result download positive mock>
node - <failed result requeue mock>
```

Passing evidence:

- Backend mini geometry is `1200x1908` with image vertices `[[82,150],[1118,150],[1118,1533],[82,1533]]`.
- Backend wide geometry is `2400x1908` with image vertices `[[82,150],[2318,150],[2318,1533],[82,1533]]`.
- `scripts/check_polaroid_size.py` passed for explicit mini, explicit wide, auto mini, auto wide, missing size, and invalid size fallback.
- `scripts/check_large_result_routes.py` passed for 60 status result metadata entries, `/api/result` ids `0`, `39`, `40`, and `59`, plus a fresh `/api/process` upload after high-count result downloads.
- `scripts/check_postprocessing_modes.py` passed, so the postprocessing contract remains intact.
- Frontend positive mock confirmed 45 returned results stay visible immediately, only 3 result downloads are active while the rest are queued, queued downloads drain without evicting retained results, duplicate result merges preserve `localPath` and `downloadStatus`, late result tap download failure sets persistent error status, upload failure performs initial upload plus 3 retries, and the empty-preview helper/result rendering markers exist.

Failing evidence:

```text
AssertionError [ERR_ASSERTION]: failed result should not be requeued by later status prefetch
4 !== 2
```

The failure was reproduced by:

1. Creating one result with no `localPath`.
2. Letting the eager queue fail original download plus one retry, leaving `downloadStatus=failed`.
3. Merging a duplicate backend status result for the same id.
4. Calling `prefetchResultImages` again.
5. Observing the result re-enter the download queue with a new retry budget.

## Verdict

changes requested
