# Taskboard

## Current Objective

Fix mini-program lifecycle and download state loss: returning from background must not re-verify token or wipe selected/extracted content, interrupted downloads must surface partial failures, and New Task must preserve any source image whose extracted polaroids were not fully saved.

Scope constraints:

- Use the agreed V1 approach: no new batch backend API unless Backend finds a blocker.
- Frontend submits selected images sequentially to the existing `/api/process` single-image task API.
- Preserve token/auth behavior, RunPod startup, SAM/extraction internals other than output-size handling, result download auth, and existing single-image behavior.
- Preserve white-balance behavior as a separate switch; postprocessing mode controls only denoise/sharpen after perspective warp and optional white balance.
- Batch result order must be: selected image order, then detected polaroid order inside each image.
- Continue processing later images if one image fails; report partial failures clearly.
- Maximum selected images: 9.

## Current Workspace State

Required fields:

```text
Branch: codex/pm-next
Worktree: C:\Users\20888\Desktop\chekinana-pm
Git status: clean at task start
Relevant existing changes:
  Frontend direct/simple commit: 29fa626 frontend: remove contact placeholders
  Frontend contact dialog approved baseline includes c2027c4 and 29fa626
  Backend contact payload baseline: 0e634c3
  Reviewer contact dialog approval baseline: d5925e9
Task branch names:
  PM: codex/pm-next
  Backend: codex/backend-next
  Frontend: codex/frontend-next
  Reviewer: codex/reviewer-next
Reviewer batch review commit: 99e8ba4
Reviewer batch UI approval commit: bb92d5b
Reviewer processing/contact review commit: 9cea878
Reviewer contact email approval commit: 1497688
Integration push: 7e6b03d main includes approved batch/contact work
Frontend preview/status fix commit: 091947e
Reviewer preview/status approval commit: 8c99538
Integration push: f3b60ed main includes approved preview/status fixes
Backend upload/status contract commit: d765c72
Frontend upload/status fix commit: 7ce31e5
Reviewer upload/status review commit: 72a4369
Frontend upload cancel endpoint commit: f644539
Reviewer upload cancel endpoint approval commit: e07e1e8
Integration push: dcda349 main includes approved upload/status fixes
Frontend rotation/timeout/action commits: 9105b7f, c056be0, 3163107
Reviewer rotation/timeout/action partial approval commit: b315634
Reviewer shortage-status changes-requested commit: 1873ae9
Frontend shortage status commits: e3488e3, b698c4b
Reviewer shortage status approval commit: 1ee2872
Integration push: d34815b main includes approved rotation/timeout/action and shortage-status fixes
Confirmed mini/wide mask geometry: 2026-06-18
Frontend polaroid size commit: 86ddbe2
Backend polaroid size commit: ff9851a
Reviewer polaroid size approval commit: 85a7ed4
User-reported upload error screenshot: 2026-06-18 `uploadFile:fail Error: Client network socket disconnected before secure TLS connection was established`
Postprocessing spec: C:\Users\20888\Desktop\cheki\POSTPROCESSING.md
Real-device image picker failure: 2026-06-21 selecting an album image in real WeChat can fail before the image is added to the mini program; retrying can fail again.
Frontend image picker fix commit: 506cf46
Reviewer image picker approval commit: fabafd7
User-reported lifecycle/download issue: 2026-06-21 switching WeChat or the mini program to background can return to auth and lose extraction content; switching during download can silently lose some images.
```

## Worktree Assignments

| Role | Worktree | Branch | Task |
|---|---|---|---|
| PM | `C:\Users\20888\Desktop\chekinana-pm` | `codex/pm-next` | Maintain taskboard, contract, scope, and readiness decision only |
| Frontend | `C:\Users\20888\Desktop\chekinana-frontend` | `codex/frontend-next` | Own `STATE-FE-001`: lifecycle state preservation and download failure tracking |
| Backend | `C:\Users\20888\Desktop\chekinana-backend` | `codex/backend-next` | No lifecycle/download implementation task unless PM reopens backend scope |
| Reviewer | `C:\Users\20888\Desktop\chekinana-reviewer` | `codex/reviewer-next` | Own `STATE-REV-001`: review lifecycle/download state fix |

## Current Tasks

| ID | Owner | Status | Task | Files | Acceptance Criteria |
|---|---|---|---|---|---|
| BATCH-FE-001 | Frontend | done | Replace the single-image selection state with a selected-images list while preserving the existing single-image workflow. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-17-frontend-batch-images.md` | Frontend commits `94471d5` through `9865fe4` implement selection up to 9, add-more behavior, and selected-image state. |
| BATCH-FE-002 | Frontend | done | Implement current-image preview management for multiple selected images. | Same Frontend files and same handoff as `BATCH-FE-001` | Frontend implements one large current-image preview, left/right navigation, delete-on-preview, index clamping, and thumbnail strip; UI blockers were resolved by `BATCH-FE-005`. |
| BATCH-FE-003 | Frontend | done | Bind polaroid count and rotation to the current image. | Same Frontend files and same handoff as `BATCH-FE-001` | Reviewer mock checks passed for independent per-image count and rotation state. |
| BATCH-FE-004 | Frontend | done | Process selected images sequentially and aggregate ordered results. | Same Frontend files and same handoff as `BATCH-FE-001` | Reviewer mock checks passed for sequential processing, partial success, all-failed behavior, selected-image order, and task-scoped result keys. |
| BATCH-BE-001 | Backend | done | Audit and verify that the existing single-image backend task API safely supports V1 sequential batch orchestration. | `docs/agents/handoffs/2026-06-17-backend-batch-images.md` | Backend commit `d1af90d` adds a handoff only; no backend code changes. Reviewer confirmed existing API/rate-limit behavior supports normal 9-image sequential batches and no new batch API is needed. |
| BATCH-REV-001 | Reviewer | done | Review the batch image implementation after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-batch-images.md` | Reviewer commit `99e8ba4` verdict: changes requested. Core batch logic and Backend compatibility are acceptable, but Frontend has blocking UI issues. |
| BATCH-FE-005 | Frontend | done | Fix remaining batch UI blockers from Reviewer and user visual feedback. | `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `wechat-miniprogram/pages/index/index.js`, `docs/agents/handoffs/2026-06-17-frontend-batch-ui-fixes.md` | Frontend commit `c0f2d39` fixes toolbar button sizing, preview navigation rendering, 9-thumbnail layout, and thumbnail tap-to-jump. |
| BATCH-REV-002 | Reviewer | done | Re-review the batch UI fixes after the Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-batch-ui-fixes.md` | Reviewer commit `bb92d5b` verdict: approved. The two P2 UI findings and the 9-thumbnail tap-to-jump requirement are resolved. |
| BATCH-FE-006 | Frontend | done | Fix processing-time interaction, interrupt behavior, incremental result display, and batch status text found during user testing. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-17-frontend-batch-processing-ux.md` | Frontend commit `3dc750d` passed reviewer checks: processing-time thumbnail/left-right navigation remains usable, interrupt calls `POST /api/cancel/<task_id>`, already received results remain visible, stale callbacks do not resume work, incremental status results display immediately, and status text includes "正在提取第2张 (2/2)" style wording. |
| BATCH-BE-002 | Backend | done | Add backend task cancellation support so the interrupt button terminates the active extraction task. | `backend/app.py`, `docs/agents/handoffs/2026-06-17-backend-task-cancel.md` | Backend commit `02ec512` passed reviewer checks: protected `POST /api/cancel/<task_id>`, queued cancel, processing cancel state, canceled status, result compatibility for produced outputs, unauthorized cancel rejection, and no RunPod/startup changes. |
| CONTACT-BE-002 | Backend | done | Finish contact-author email success logging and handoff for the existing contact email behavior. | `backend/app.py`, `docs/agents/handoffs/2026-06-17-backend-contact-email-log.md` | Backend commit `ef6d945` adds safe successful-send logging for contact emails without logging full message/contact values. Reviewer verified contact info remains in the email body and route/auth/rate-limit/response behavior remains compatible. |
| BATCH-REV-003 | Reviewer | done | Review the processing UX, backend cancellation, and contact email/log fixes after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-batch-processing-contact-fixes.md` | Reviewer commit `9cea878` verdict: changes requested. Frontend processing UX and Backend cancellation passed; contact email includes contact info; blocker remains Backend missing successful-send log and missing `CONTACT-BE-002` handoff. |
| CONTACT-REV-003 | Reviewer | done | Re-review `CONTACT-BE-002` after Backend adds success logging and the missing handoff. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-contact-email-log.md` | Reviewer commit `1497688` verdict: approved. Successful contact email sends now produce the required safe log, contact info remains visible in the email body when provided, no sensitive full message/contact value is logged, and existing `/api/contact` behavior remains compatible. |
| BATCH-FE-007 | Frontend | done | Fix post-integration preview rotation and status-phase text issues found during mini-program testing. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-17-frontend-preview-status-fixes.md` | Frontend commit `091947e` passed reviewer checks: preview now uses per-image generated `previewPath` instead of preview-frame rotation transforms, switching differently rotated images updates source/orientation together, upload/backend-waiting/queued/processing phases are distinct, queued status includes queue position when available, incremental result display and interrupt/cancel behavior remain intact, and no backend API contract changed. |
| BATCH-REV-004 | Reviewer | done | Review `BATCH-FE-007` after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-preview-status-fixes.md` | Reviewer commit `8c99538` verdict: approved. Reviewer confirmed the diff is scoped to Frontend preview/status behavior, no Backend/auth/contact/result API contracts changed, `node --check` and `git diff --check` passed, and mocked checks covered rotated-image switching, upload status, queued status with queue position, processing progress, incremental display, and interrupt. |
| BATCH-BE-003 | Backend | done | Add backend support for active-task status and pre-task upload cancellation. | `backend/app.py`, `docs/agents/handoffs/2026-06-17-backend-upload-status-contract.md` | Backend commit `d765c72` implements active processing task fields in `/api/status/<task_id>` and pre-task upload cancellation. Reviewer smoke confirmed `POST /api/upload-cancel/<upload_attempt_id>` records cancellation and a late `/api/process` with the same `upload_attempt_id` returns 409 without queuing. No Backend follow-up is required unless Frontend alignment or re-review finds a regression. |
| BATCH-FE-008 | Frontend | done | Fix thumbnails, upload timeout/retry, pre-task interrupt, and active-task-based status display. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-17-frontend-upload-status-fixes.md` | Frontend commit `7ce31e5` implements rotated thumbnails, bounded upload timeout/retry, upload attempt ids, abort handling, active-task-based status helpers, and stale callback guards. Its only review blocker was the pre-task cancel endpoint mismatch; `BATCH-FE-009` fixed that blocker and `BATCH-REV-006` approved the end-to-end behavior. |
| BATCH-REV-005 | Reviewer | done | Review `BATCH-BE-003` and `BATCH-FE-008` together after both handoffs are available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-upload-status-fixes.md` | Reviewer commit `72a4369` verdict: changes requested. Blocking P1: Frontend and Backend implemented different pre-task upload cancel endpoints, so an interrupted/timed-out upload can still arrive late at `/api/process` and be queued. Rotated thumbnails, upload timeout/retry scaffolding, active-task status fields, and active-task-based status helpers were otherwise reviewed. |
| BATCH-FE-009 | Frontend | done | Align pre-task upload cancel endpoint with the Backend canonical route. | `wechat-miniprogram/pages/index/index.js`, `docs/agents/handoffs/2026-06-17-frontend-upload-cancel-endpoint.md` | Frontend commit `f644539` uses Backend's canonical protected endpoint `POST /api/upload-cancel/<upload_attempt_id>` for all pre-task upload cancellation calls and no longer uses `/api/upload-attempts/<upload_attempt_id>/cancel`. Handoff verification covered `node --check`, `git diff --check`, timeout canonical cancel, interrupt-before-task canonical cancel, and canonical route checks. |
| BATCH-REV-006 | Reviewer | done | Re-review `BATCH-FE-009` endpoint alignment after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-upload-cancel-endpoint.md` | Reviewer commit `e07e1e8` verdict: approved. Reviewer confirmed Frontend sends `POST /api/upload-cancel/<upload_attempt_id>`, timeout and interrupt-before-task-id use the canonical route, interrupt after `task_id` still uses `/api/cancel/<task_id>`, Backend rejects late canceled uploads with 409 and does not queue them, normal uploads still queue, active task fields remain in status, and auth behavior is not loosened. |
| BATCH-FE-010 | Frontend | done | Fix rotated preview reliability, upload timeout/retry limits, queued status copy, final insufficient-count status, and completed-batch actions. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss` if needed, `docs/agents/handoffs/2026-06-17-frontend-rotation-timeout-queue.md` | Frontend commits `9105b7f`, `c056be0`, and `3163107` implement rotation reliability/fallback behavior, 15-second upload timeout with max 2 retries, queued copy without queue position, completed-batch actions, and related UI checks. Reviewer commit `b315634` approved the original rotation/timeout/queue/action scope; the later shortage-status blocker from `1873ae9` was fixed by `BATCH-FE-011` and approved by `BATCH-REV-008`. |
| BATCH-REV-007 | Reviewer | done | Review `BATCH-FE-010` after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-rotation-timeout-queue.md` | Final reviewer verdict is changes requested in commit `1873ae9`. Prior commit `b315634` approved rotation fallback, keyed preview switching, 15-second timeout with 2 retries, queued copy, active-task status, all-download, clear-successful-images, failed-image preservation, and cancel route behavior. Blocking P1 remains Frontend shortage status: when the user expects 5 but Backend completion reports actual counts as 3, both single-image and batch completion paths can show success instead of final `3/5` shortage. |
| BATCH-FE-011 | Frontend | done | Fix final insufficient-count status to preserve the user-entered expected count. | `wechat-miniprogram/pages/index/index.js`, `docs/agents/handoffs/2026-06-18-frontend-shortage-status.md` | Frontend commits `e3488e3` and `b698c4b` preserve the user-entered expected count, or `payload.requested_polaroids` when available, before falling back to Backend actual/finalized count fields. Final single-image and batch completion now show shortages such as `3/5` when the user expected 5 but Backend actual completion fields are 3, while preserving partial results and failed source image indexes. |
| BATCH-REV-008 | Reviewer | done | Re-review `BATCH-FE-011` after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-18-reviewer-shortage-status.md` | Reviewer commit `1ee2872` verdict: approved. Reviewer confirmed single-image direct and polling completion, requested-polaroids fallback, batch direct and polling completion, and final batch status all show `3/5` shortages while preserving partial results. Regression checks covered rotation, 15-second timeout with 2 retries, canonical pre-task upload cancel, task cancel, all-download, and clear-successful-images preserving failed source images. |
| SIZE-FE-001 | Frontend | done | Add per-image polaroid size selector and submit it with processing requests. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-18-frontend-polaroid-size.md` | Frontend commit `86ddbe2` adds a preview-area `auto / mini / wide` selector, defaults every newly selected image to `mini`, persists size per image across switching/rotation/deletion/batch processing, and submits `polaroid_size` with single-image and batch `/api/process` uploads. Reviewer verified default mini, independent per-image size state, selector placement/state, upload fields, and count/rotation compatibility. |
| SIZE-BE-001 | Backend | done | Add mini/wide/auto output-size support for extracted polaroids. | `backend/app.py`, `scripts/check_polaroid_size.py`, `docs/agents/handoffs/2026-06-18-backend-polaroid-size.md` | Backend commit `ff9851a` accepts `polaroid_size=auto|mini|wide`, falls back to `mini` for missing/invalid values, preserves mini output `1600x2544` with vertices `[[110,200],[1490,200],[1490,2044],[110,2044]]`, adds wide output `3200x2544` with vertices `[[110,200],[3090,200],[3090,2044],[110,2044]]`, and classifies `auto` per quadrilateral with horizontal/vertical edge ratio `> 1` as wide. Reviewer verified geometry, explicit mini/wide, auto classification, default fallback, and no route/auth/startup regressions. |
| SIZE-REV-001 | Reviewer | done | Review mini/wide/auto polaroid size support after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-18-reviewer-polaroid-size.md` | Reviewer commit `85a7ed4` verdict: approved. Reviewer confirmed Frontend selector and upload behavior, Backend mini/wide geometry, `auto` classification, fallback to mini, selected geometry passed into fixed-border white balance, and no regressions to `/api/cancel/<task_id>`, `/api/upload-cancel/<upload_attempt_id>`, auth token flow, result routes, contact route/UI, RunPod startup, upload timeout/retry, rotation preview, shortage status, all-download, or clear-successful-images behavior. |
| BATCH-FE-012 | Frontend | done | Fix batch completion status, post-completion navigation, completed action copy, and upload socket/TLS failure handling. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `docs/agents/handoffs/2026-06-18-frontend-completion-upload-regressions.md` | Frontend commit `38a5cf6` lists all insufficient-count images in final batch status, preserves extracted results/status/actions during completed preview navigation, routes socket/TLS `wx.uploadFile` failures through bounded retry/cancel/sanitized failure handling, and renames the completed reset action to `新任务` while preserving failed source images. Reviewer mocks confirmed all four reported regressions and all-download/per-image size regressions. |
| BATCH-BE-004 | Backend | done | Verify backend compatibility for upload socket/TLS failures and current batch status/cancel contracts. | `docs/agents/handoffs/2026-06-18-backend-upload-failure-compat.md` | Backend commit `ef48414` documents that the TLS/socket upload failure can occur before Flask receives a request, so no Backend code change is required. Reviewer smoke confirmed `/api/upload-cancel/<upload_attempt_id>`, late canceled `/api/process` 409, normal `/api/process`, active-task status fields, result routes, and `/api/cancel/<task_id>` remain compatible. |
| BATCH-REV-009 | Reviewer | done | Review `BATCH-FE-012` and `BATCH-BE-004` after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-18-reviewer-completion-upload-regressions.md` | Reviewer verdict: approved. Required frontend and backend checks passed: multiple shortage aggregation, post-completion navigation preserving results, socket/TLS upload failure retry/cancel/sanitization, `新任务` label/failed-source preservation, all-download, per-image `polaroid_size`, active-task/cancel/upload-cancel/result/contact/auth compatibility, `node --check`, `python -m py_compile`, and `git diff --check`. |
| POST-FE-001 | Frontend | done | Replace the existing denoise switch with a three-option postprocessing selector, adjust count-input layout, and add the `izaya7` map page route. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, token/auth page files, new map page files, `wechat-miniprogram/app.json`, `docs/agents/handoffs/2026-06-19-frontend-postprocessing-map.md` | Frontend commit `cf36d6c` replaces the denoise switch with `关闭 / 降噪 / 锐化`, defaults to `降噪`, submits `postprocess_mode` plus legacy `denoise` for single and batch `/api/process`, preserves `wb`, rotation, per-image `polaroid_size`, upload retry/cancel, ordering, completed navigation, and failed-source behavior, narrows the count input, and adds exact `izaya7` navigation to a blank page titled `izaya7's map` without storing the value or calling backend auth. Reviewer mock verified selector state, payload fields, route behavior, and normal auth. |
| POST-BE-001 | Backend | done | Implement conservative postprocessing modes from `POSTPROCESSING.md`. | `backend/app.py`, optional focused scripts/tests, `docs/agents/handoffs/2026-06-19-backend-postprocessing-modes.md` | Backend commit `c3bc24f` accepts `postprocess_mode=off|denoise|sharpen`, preserves absent-field legacy `denoise=0/1`, falls back to `denoise` for missing/invalid modes, performs fixed-border white balance in `linear_rgb`, runs LAB-channel NLM denoise with L `h=3.5` and A/B `h=6.0`, runs sharpen as denoise plus LAB L-channel USM `sigma=1.0`, `amount=0.45`, `threshold=3.0`, and exposes `postprocess_mode` and `white_balance_color_space` metadata without changing RunPod startup, auth, queue/cancel, result routes, mini/wide/auto geometry, contact route, or SAM detection. Reviewer backend scripts passed. |
| POST-REV-001 | Reviewer | done | Review `POST-FE-001` and `POST-BE-001` after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-19-reviewer-postprocessing-map.md` | Reviewer verdict: approved. Required checks passed: Frontend `node --check`, Backend `python -m py_compile`, `git diff --check`, targeted Frontend payload/auth/map mocks, `scripts/check_postprocessing_modes.py`, and `scripts/check_polaroid_size.py`. Reviewer confirmed selector labels/default/placement, single/batch `postprocess_mode`, count input layout, exact `izaya7` map route, normal auth unchanged, linear-RGB white balance, LAB denoise/sharpen order and parameters, `off` behavior, legacy compatibility, status metadata, mini/wide/auto preservation, and no reviewed diff touching RunPod startup, contact, result, task cancel, or upload-cancel contracts. |
| MAIN-SYNC-001 | PM | done | Summarize the large `origin/main` update that was merged into every agent worktree. | `docs/agents/handoffs/2026-06-21-main-sync-briefing.md` | PM documented the six commits from `5e17549` to `d914343`, the new navigation/calendar/izaya7-map/page-placeholder structure, per-agent impact notes, and risks for future Frontend/Backend/Reviewer work. All agents must read this briefing before working in files touched by the main sync. |
| PICK-FE-001 | Frontend | done | Fix real WeChat image picker failures before upload starts. | `wechat-miniprogram/pages/index/index.js`, `docs/agents/handoffs/2026-06-21-frontend-image-picker.md` | Frontend commit `506cf46` hardens the picker path by preferring `wx.chooseImage`, retaining `wx.chooseMedia` only as a compatibility fallback, normalizing returned temp paths, treating user cancel as a no-op, logging non-cancel picker failures, preserving add-more behavior and max 9 images, and leaving upload/backend/status contracts unchanged. |
| PICK-REV-001 | Reviewer | done | Review the image-picker fix after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-21-reviewer-image-picker.md` | Reviewer commit `fabafd7` verdict: approved. Reviewer confirmed the `wx.chooseImage` path, fallback behavior, cancel/failure handling, result normalization, add-more and 9-image limit behavior, per-image defaults, main-sync route preservation, and no changes to `/api/process`, upload/cancel/status/result, `postprocess_mode`, `polaroid_size`, or rotation contracts. |
| STATE-FE-001 | Frontend | pending | Preserve extraction state across background/auth lifecycle and track download/save failures. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml` if UI state is needed, `wechat-miniprogram/pages/index/index.wxss` if needed, `docs/agents/handoffs/2026-06-21-frontend-lifecycle-download-state.md` | After token verification succeeds on the auth page and enters index, index must not re-verify the token on `onShow`, foreground return, tab switch, or normal page lifecycle. The app should only leave the authenticated scanner flow when no token exists or the user manually clears token in settings. Therefore background return must not clear selected images, extracted results, failed-image markers, completed status/actions, or current preview. Track per-result album-save success/failure for both single-result save and all-download flows; if switching apps interrupts download/save, show a visible partial-failure result instead of silently losing images. `新任务` must keep any source image and all extracted results from that source when none of its polaroids were saved or when any save/download failed or remains unknown; it may clear only source-image groups whose extracted results all saved successfully and that are not failed source images. After processing is complete, manually deleting a single selected source image is an explicit delete action and must delete only that source image plus extracted results from that source, without checking whether those results were downloaded/saved; all other source images, extracted results, download/save state, completed status/actions, and failed-source markers must remain consistent, including reindexing source-image references if index-based fields are still used. Preserve batch ordering, existing upload/process/status/cancel contracts, picker behavior, `postprocess_mode`, `polaroid_size`, rotation, settings manual-token-clear behavior, and main-sync tab/calendar/map routes. |
| STATE-REV-001 | Reviewer | pending | Review `STATE-FE-001` after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-21-reviewer-lifecycle-download-state.md` | Reviewer must inspect the Frontend diff and handoff, confirm no Backend/API scope was added, and verify index does not call token verification on `onShow`/foreground return after auth-page success, missing token still routes to auth, settings manual token clear still exits authenticated flow, background return preserves scanner state, download/save partial failures are visible, per-result save tracking works, `新任务` preserves unsaved/failed/unknown source-image groups, and completed-state single-image delete removes only that source image and its extracted results without checking download/save status while preserving and reindexing remaining groups correctly. Also verify no regressions to image picker, batch processing, result display, upload cancel/task cancel, all-download success path, custom tab bar, calendar, and `izaya7-map`. Reviewer should run `node --check`, `git diff --check`, and targeted mocks for foreground return without reverify, missing token redirect, settings clear-token behavior if present, interrupted all-download, partial save failure, New Task cleanup rules, and completed-state single-image delete. |

Status values:

```text
pending
in_progress
blocked
review
done
paused
```

## API / Configuration Contract

V1 keeps the existing single-image task API.

Image picker contract:

- The failing path occurs before `/api/process`; the mini program has not yet uploaded an image or received a backend `task_id`.
- Frontend should use the most stable real-WeChat image-only picker path and normalize returned local temp paths into the existing selected-image list.
- `wx.chooseImage` is acceptable and preferred for this image-only use case if it avoids the real-device `wx.chooseMedia` failure; keep a compatibility fallback only when it improves coverage.
- User cancel must not be treated as an error toast.
- Non-cancel picker failures should be logged with the raw error for debugging and shown as a concise user-facing image selection failure.
- The picker fix must preserve camera and album source support, selecting multiple images up to the remaining 9-image limit, adding images after an existing selection, and all per-image state defaults.
- No Backend API change is expected; do not involve Backend for this picker fix unless Frontend later finds a concrete upload contract blocker and PM reassigns scope.

Lifecycle and download-state contract:

- Token verification is required only on the auth page before entering index.
- After auth-page verification succeeds and stores the token, index must not re-verify the token on `onShow`, foreground return, tab switch, or normal page lifecycle.
- The app should leave the authenticated scanner flow only when no token exists locally or the user manually clears token in settings.
- Returning from background, switching apps, or resuming the mini program must not clear scanner state through automatic token re-verification or auth redirects.
- Scanner state includes selected source images, current image index, rotated preview state when available, extracted result list, failed source image indexes, completed/partial status text, completed actions, and download/save status for each result.
- Download/save flows must track per-result status at least as `pending/unknown`, `saved`, and `failed` or equivalent internal states.
- All-download must show a visible completion/partial-failure message when one or more results fail to download or save, including failures caused by backgrounding or app switching.
- Single-result save failures should update the same per-result tracking used by all-download, so the later New Task decision is consistent.
- `新任务` after processing must preserve a source image and all extracted results from that source if that source has no saved results, any failed result, or any unknown/unsaved result.
- `新任务` may clear only source-image groups whose extracted polaroids all saved successfully and whose source image is not otherwise marked failed.
- Manual single-source-image deletion after processing is different from `新任务`: it is an explicit delete action and should delete the selected source image and that source's extracted results regardless of download/save status.
- Manual single-source-image deletion must preserve all other source images and extracted results; if the implementation uses index-based fields such as `sourceImageIndex` or `failedImageIndexes`, remaining groups must be reindexed consistently after deletion.
- This task does not change Backend result URLs or add a new result bundle/zip API.

Frontend request flow:

- For each selected image, submit one `POST /api/process` request with multipart field `image`.
- Submit images sequentially in selected-image order.
- Include existing form fields per image:
  - `token`
  - `wb`
  - legacy `denoise` if needed for compatibility
  - `postprocess_mode` (`off`, `denoise`, or `sharpen`; default `denoise`)
  - `rotation_degrees`
  - `polaroid_size` (`auto`, `mini`, or `wide`; default `mini`)
  - optional `expected_polaroids`
  - optional `polaroid_count`
- Poll each returned `task_id` through existing `/api/status/<task_id>`.
- Download each result through existing `/api/result/<task_id>/<result_id>`.

Backend response contract:

- Existing `/api/process` response shape remains compatible.
- Existing `/api/status/<task_id>` fields remain compatible, including `results`, `expected_polaroids`, `total_polaroids`, `warning`, and `extraction_complete`.
- Existing `/api/result/<task_id>/<result_id>` behavior remains compatible.
- No new batch route is required for V1.

Polaroid size contract:

- Existing output size is now named `mini`.
- `mini` ratio is `1:1.59`; current output remains `1600x2544`.
- `wide` ratio is `2:1.59`; output must be `3200x2544`.
- Confirmed mini output image-area vertices are `[[110,200],[1490,200],[1490,2044],[110,2044]]`.
- Confirmed wide output image-area vertices are `[[110,200],[3090,200],[3090,2044],[110,2044]]`.
- The wide card keeps the same top/bottom blank border heights as mini and the same left/right blank border widths as mini; only the total width and image-area width expand.
- Frontend sends `polaroid_size` per image with value `auto`, `mini`, or `wide`; absent value must behave as `mini`.
- If `polaroid_size=mini`, Backend warps every detected quadrilateral to mini output.
- If `polaroid_size=wide`, Backend warps every detected quadrilateral to wide output.
- If `polaroid_size=auto`, Backend classifies each detected quadrilateral independently using `avg(horizontal edge lengths) / avg(vertical edge lengths)`: ratio `> 1` means wide, ratio `<= 1` means mini.
- The user confirmed the mini/wide mask geometry on 2026-06-18 before task publication.

Postprocessing contract:

- Postprocessing runs after perspective warp and optional white balance.
- White balance remains controlled only by `wb`; `postprocess_mode=off` does not disable white balance.
- When `wb` is enabled, Backend must perform white balance in linear RGB space: convert sRGB to linear RGB before computing/applying white-reference gains, then convert the result back to sRGB.
- The existing fixed-border reference-block strategy and mini/wide geometry masks should remain the basis for selecting white reference pixels.
- Frontend exposes exactly three postprocessing options: `关闭`, `降噪`, `锐化`.
- Frontend sends `postprocess_mode=off|denoise|sharpen` for each `/api/process` upload.
- Backend accepts `postprocess_mode=off|denoise|sharpen`.
- Missing or invalid `postprocess_mode` must preserve current default behavior as `denoise`.
- Legacy `denoise` boolean remains compatible when `postprocess_mode` is absent: false means `off`, true means `denoise`.
- `off` means no denoise or sharpen after warp/white balance.
- `denoise` means LAB-channel NLM denoise only, following `C:\Users\20888\Desktop\cheki\POSTPROCESSING.md`.
- `sharpen` means LAB-channel NLM denoise first, then reduced USM low sharpen on LAB `L` only, following `C:\Users\20888\Desktop\cheki\POSTPROCESSING.md`.
- LAB denoise parameters: OpenCV `fastNlMeansDenoising`, L channel `h=3.5`, A/B channels `h=6.0`, `templateWindowSize=7`, `searchWindowSize=21`.
- Sharpen parameters: `sigma=1.0`, `amount=0.45`, `threshold=3.0`; color channels remain unchanged.

Frontend auth/map contract:

- The normal token authentication flow must remain unchanged for real backend tokens.
- Exact token-page input `izaya7` routes to a new blank mini-program page.
- The new page navigation title must be `izaya7's map`.
- `izaya7` must not be stored or treated as a valid backend API token.

Ordering contract:

- Overall display order is selected image order.
- Within each image, display order is backend result order, which should remain the existing detected polaroid order.
- Frontend must use a result key unique across backend tasks, such as `taskId:resultId`, to avoid merging result `0` from different images.

Failure contract:

- A failed upload, failed task, timeout, or empty extraction for one image must not stop later images from processing.
- Final UI must distinguish full success, partial success, and no successful results.
- After processing completes, failed source images must remain selectable/visible when the user clears successful images, so failed images can be retried or inspected.
- Interrupting a running batch must cancel the currently active backend task as well as stop the frontend batch flow.
- Frontend must call the Backend cancel endpoint for the active `task_id`, then stop further uploads and ignore/stop polling updates after the user interrupts.
- Backend cancellation should terminate queued tasks immediately and stop processing tasks as soon as practical through explicit cancel state checks; after cancellation it must not continue extracting additional polaroids for that task.
- Frontend must keep incremental result display: results returned during `/api/status/<task_id>` polling should appear immediately, not only after the whole source image completes.

Frontend preview/status contract:

- The preview for the selected image must render as the image in its current rotation state, not by applying a transient rotation transform to the preview frame that can affect the previously displayed image during image switches.
- Thumbnail previews must render from the same per-image rotated preview source/state as the large preview.
- Rotated preview generation must be bounded and failure-safe: if preview generation fails, times out, or becomes stale, the mini-program must keep showing the original selected image and keep the backend upload rotation value intact.
- Late rotated-preview callbacks must not overwrite a newer selected image or newer rotation state.
- Per-image rotation remains part of the existing upload contract through `rotation_degrees`; this task does not require backend API changes.
- Status text must distinguish these phases in order: upload (`图片上传中`), queued/waiting, processing/extracting, completed/partial/failed/canceled.
- Final status text must report insufficient extracted polaroids when the final received count is lower than the expected count, including received/expected counts when available.
- If multiple source images finish with insufficient extracted polaroid counts, the final status bar must include every insufficient image rather than only the first one.
- For final shortage display, a user-entered expected count, or Backend `requested_polaroids` that preserves that user input, is authoritative over Backend actual count fields such as `total_polaroids` and `expected_polaroids`.
- Backend actual count fields must not hide a shortage by replacing a larger user-entered target during final completion.
- Queued/waiting state must be derived from the backend's active processing task id for the current status response, not from `queue_position: 0` or from an initial queued upload response alone.
- If the backend reports that the active processing task id matches the current image's `task_id`, the frontend must show processing/detecting/extracting status for that image even if no polaroid result has been returned yet.
- If the backend reports another active processing task id, the frontend may show queued/waiting for the current image but must not display queue position.
- If no backend active processing task id is present and the current task is not yet active, the frontend should show backend waiting rather than incorrectly claiming another task is in the queue.
- After processing completes, left/right preview navigation and thumbnail navigation must remain side-effect-free for extraction results: navigation may switch the selected source preview only and must not clear result lists, failed-image markers, completed status, or completed actions.
- Completed processing actions should replace the normal two action buttons with `全部下载` and `新任务`; `全部下载` applies to every extracted polaroid result, while `新任务` keeps the existing completed-task reset behavior that clears successfully processed source images but preserves failed source images when any exist.

Upload timeout/cancel contract:

- Frontend must generate a unique upload attempt id for each image upload attempt and include it in the `/api/process` request.
- Backend must provide a protected way to record an upload attempt id as canceled before `/api/process` returns a `task_id`.
- The canonical pre-task upload cancel endpoint is `POST /api/upload-cancel/<upload_attempt_id>`.
- If a late `/api/process` request arrives with an upload attempt id already marked canceled, Backend must not enqueue or extract that image.
- Frontend must abort timed-out or interrupted `wx.uploadFile` attempts when possible and send the pre-task cancel signal for the upload attempt id.
- Upload timeout is 15 seconds per upload attempt before retry/cancel handling begins.
- Upload timeout retry is capped at 2 retries per image upload attempt.
- Transient `wx.uploadFile` network/socket/TLS failures, including `Client network socket disconnected before secure TLS connection was established`, must be handled by the same bounded retry/failure path as upload timeouts; they must not leave the UI stuck in upload state or let stale late callbacks mutate a newer task.
- Once `/api/process` returns a `task_id`, existing `/api/cancel/<task_id>` remains the cancellation path for queued or processing backend tasks.

Backend cancellation contract:

- Add a protected task cancellation endpoint for the existing task model, for example `POST /api/cancel/<task_id>`.
- Successful cancellation returns a JSON response compatible with existing frontend request handling, for example `{ "ok": true, "status": "canceled" }`.
- `/api/status/<task_id>` must expose a clear canceled status after cancellation.
- Unauthorized cancel requests must be rejected the same way as other protected `/api/*` routes.

Contact email contract:

- `POST /api/contact` keeps the existing route, auth, rate limit, and response shape.
- Optional `contact` must be included in the email body when provided and omitted when empty.
- Backend must log successful contact email sends as well as failures.

## Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-06-16 | Use V1 sequential orchestration on top of existing single-image `/api/process`. | Avoids a larger backend batch-task redesign and keeps extraction internals stable. |
| 2026-06-16 | Limit selected images to 9. | Keeps upload volume within WeChat and backend rate-limit constraints for the first batch version. |
| 2026-06-16 | Bind count input and rotation state to the current image. | User explicitly requested per-image counts and rotations while previewing one image at a time. |
| 2026-06-16 | Tapping an already selected preview should offer delete only. | User explicitly changed the preview tap behavior from replace to delete. |
| 2026-06-16 | Continue after individual image failures and preserve ordered successful results. | Provides useful partial output for long batches and matches the agreed V1 behavior. |
| 2026-06-17 | Route remaining batch work to Frontend UI only. | Reviewer approved core batch logic and Backend compatibility, while all open blockers are display/navigation issues in the mini-program UI. |
| 2026-06-17 | Thumbnail strip must show all 9 selected images and support tap-to-jump. | User added this visual requirement after review; it belongs with the same Frontend UI fix. |
| 2026-06-17 | Interrupt must cancel the active backend extraction task, not just frontend orchestration. | User explicitly clarified that the interrupt button should terminate the backend task currently extracting. |
| 2026-06-17 | Preserve incremental polaroid display during batch processing. | User expects the original behavior where each returned polaroid appears as soon as the backend reports it. |
| 2026-06-17 | Reopen Backend contact-email work for delivered contact info and success logs. | User testing found optional contact info is not visible in the email and successful sends are not logged. |
| 2026-06-17 | Keep the next fix Backend-only for contact success logging. | Reviewer verified Frontend processing UX, Backend cancellation, and contact email body behavior; only Backend success logging and handoff remain incomplete. |
| 2026-06-17 | Batch/contact work is ready for integration after reviewer approval. | Reviewer approved `CONTACT-REV-003` in commit `1497688`; no open implementation tasks remain. |
| 2026-06-17 | Reopen Frontend batch work for post-integration preview/status issues. | User testing after integration found three UI problems: rotated preview switching, lost upload phase text, and missing queued/waiting status display. |
| 2026-06-17 | Keep the preview/status fix Frontend-only unless implementation discovers a real backend contract gap. | The requested behavior can be expressed through existing per-image rotation state and existing task status polling; backend batch/cancel/contact contracts should stay stable. |
| 2026-06-17 | Preview/status fixes are ready for integration after reviewer approval. | Reviewer approved `BATCH-REV-004` in commit `8c99538`; no open implementation or review tasks remain. |
| 2026-06-17 | Reopen batch work for thumbnail rotation, upload timeout/cancel, and active-task status. | User testing after integration `f3b60ed` found three remaining issues that need coordinated Frontend and Backend fixes. |
| 2026-06-17 | Queue display must follow Backend active processing task id. | `queue_position: 0` and stale queued upload responses can mislabel active SAM detection/extraction as queued; the backend's active task id is the authoritative signal. |
| 2026-06-17 | Upload timeout/cancel needs a pre-task upload attempt id contract. | A stuck upload may not have a backend `task_id`; canceling only by task id cannot stop a late upload from later being accepted and processed. |
| 2026-06-17 | Canonical pre-task upload cancel endpoint is `POST /api/upload-cancel/<upload_attempt_id>`. | Reviewer found Frontend and Backend implemented different routes; Backend's route already passed the late-upload rejection smoke, so Frontend should align to it. |
| 2026-06-17 | Upload/status follow-up fixes are ready for integration after reviewer approval. | Reviewer approved `BATCH-REV-006` in commit `e07e1e8`; no open implementation or review tasks remain. |
| 2026-06-17 | Keep the rotation/timeout/queue copy follow-up Frontend-only. | User-reported issues are mini-program preview generation, upload attempt timeout duration, and status text copy; existing Backend APIs remain sufficient. |
| 2026-06-17 | Queued status should omit queue position. | With current single-worker/sequential frontend flow, the displayed queue position is always 1 and adds noise rather than useful information. |
| 2026-06-17 | Upload timeout retries are capped at 2. | User clarified the maximum retry count after setting the timeout duration to 15 seconds. |
| 2026-06-17 | Final status must show insufficient polaroid count after all processing finishes. | User expects count shortage to be visible in the completed status bar, not only during processing or hidden in partial results. |
| 2026-06-17 | Completed processing actions should be `全部下载` and `删除全部图片`. | User wants result-focused actions after processing; failed source images should remain so they can be retried or reviewed. |
| 2026-06-18 | User-entered expected count is authoritative for final shortage display. | Reviewer found Backend completion can reduce `total_polaroids` / `expected_polaroids` to the actual detected count, which hides shortages unless Frontend preserves the original user target. |
| 2026-06-18 | Rotation/timeout/action and shortage-status fixes are ready for integration after reviewer approval. | Reviewer approved `BATCH-REV-008` in commit `1ee2872`; no open implementation or review tasks remain. |
| 2026-06-18 | Add `mini`, `wide`, and `auto` polaroid size support. | User requested a second wide format equivalent to two mini polaroids side by side, plus frontend per-image selection. |
| 2026-06-18 | Keep `mini` as the default size. | Existing behavior must remain compatible unless the user explicitly selects `auto` or `wide`. |
| 2026-06-18 | Confirmed wide image-area geometry before implementation. | User approved the mask where wide keeps mini top/bottom/left/right margins and expands width to `3200x2544` output with vertices `[[110,200],[3090,200],[3090,2044],[110,2044]]`. |
| 2026-06-18 | Auto size classification uses horizontal/vertical edge ratio threshold `1`. | User specified comparing horizontal edge lengths to vertical edge lengths against 1, accounting for vertical compression from normal photo perspective. |
| 2026-06-18 | Polaroid size support is ready for integration after reviewer approval. | Reviewer approved `SIZE-REV-001` in commit `85a7ed4`; no open implementation or review tasks remain. |
| 2026-06-18 | Publish post-size batch completion/upload regression tasks in Frontend, Backend, Reviewer order. | User testing found multiple shortage-status aggregation, completed navigation result loss, upload socket/TLS failure, and completed action copy issues. |
| 2026-06-18 | Keep the main fix Frontend-owned unless Backend audit finds a real contract gap. | The reported symptoms are mini-program status/action/navigation/upload-error handling, while existing Backend cancel/status/upload-cancel APIs should be sufficient if confirmed. |
| 2026-06-18 | Completed clear action text changes from `删除全部图片` to `新任务`. | User explicitly requested the completed-state button label change while preserving the completed reset behavior. |
| 2026-06-19 | Add explicit postprocessing modes `off`, `denoise`, and `sharpen`. | User requested replacing the existing denoise switch with three options and using the two-step conservative postprocessing spec from `POSTPROCESSING.md`. |
| 2026-06-19 | Keep `denoise` as the default postprocessing mode. | This preserves the current default behavior of the existing denoise switch while allowing users to opt out or choose sharpen. |
| 2026-06-19 | Treat `izaya7` as a frontend-only route trigger, not a backend token. | User requested a small token-page navigation feature; normal authentication must not be loosened. |
| 2026-06-19 | Perform white balance in linear RGB space. | User added this as a backend postprocessing requirement; white balance remains independently controlled by `wb`. |
| 2026-06-21 | Prefer a real-WeChat-compatible image-only picker path for Add image. | User testing found `wx.chooseMedia` can fail after album selection before any upload starts; `wx.chooseImage` is older and better aligned with the image-only requirement. |
| 2026-06-21 | Keep the picker fix Frontend-only with Reviewer verification. | The failure happens before `/api/process`, so Backend should not be assigned unless Frontend later finds a concrete upload contract blocker and PM reopens scope. |
| 2026-06-21 | Provide a shared main-sync briefing for all agents. | Every worktree absorbed a large `origin/main` update with navigation, calendar, and map changes; agents need the same context before editing touched files. |
| 2026-06-21 | Keep lifecycle/download state fixes Frontend-only. | The reported issues are mini-program lifecycle, index auth handling, download/save callbacks, and New Task cleanup logic; existing Backend result APIs should remain sufficient. |
| 2026-06-21 | Do not re-verify token from index after auth succeeds. | User clarified that once auth-page verification enters index, token should be trusted until the user manually clears it in settings. |
| 2026-06-21 | Treat downloaded-to-temp-file and saved-to-album as different states. | A result with `localPath` may still not be saved to the user's album, so New Task preservation must be based on album-save success, not merely download success. |
| 2026-06-21 | Preserve source-image groups unless all extracted results for that source saved successfully. | User explicitly requires images to remain when all polaroids were not downloaded or any download/save failed. |
| 2026-06-21 | Manual completed-state single-image deletion ignores download status. | User clarified that clicking one selected image and deleting it after processing should delete exactly that source image and its extracted results, even if not downloaded, while preserving other groups. |

## Open Questions

- None. Lifecycle state preservation and download failure handling have concrete Frontend and Reviewer owners; Backend is out of scope unless a concrete API blocker appears.

## Completed Work Summary

- PM discussed and captured the agreed V1 batch design before publishing this taskboard.
- Frontend implemented V1 batch behavior through `9865fe4`.
- Backend verified existing single-image API support in `d1af90d` without backend code changes.
- Reviewer completed `BATCH-REV-001` in `99e8ba4` with verdict `changes requested` for Frontend UI issues.
- Frontend fixed batch UI polish in `c0f2d39`.
- Reviewer approved `BATCH-REV-002` in `bb92d5b`.
- Frontend completed processing UX and interrupt wiring in `3dc750d`.
- Backend completed task cancellation in `02ec512`.
- Reviewer completed `BATCH-REV-003` in `9cea878` with verdict `changes requested`; only `CONTACT-BE-002` success logging/handoff remains open.
- Backend completed contact email success logging in `ef6d945`.
- Reviewer approved `CONTACT-REV-003` in `1497688`; PM marks the batch/contact work ready for integration.
- User testing after integration commit `7e6b03d` found new Frontend batch preview/status issues; PM assigned `BATCH-FE-007` and `BATCH-REV-004`.
- Frontend completed `BATCH-FE-007` in `091947e`.
- Reviewer approved `BATCH-REV-004` in `8c99538`; PM marks the preview/status fixes ready for integration.
- User testing after integration commit `f3b60ed` found thumbnail rotation, stuck upload/cancel, and stale queued-status issues; PM assigned `BATCH-BE-003`, `BATCH-FE-008`, and `BATCH-REV-005`.
- Backend completed `BATCH-BE-003` in `d765c72`.
- Frontend completed initial `BATCH-FE-008` work in `7ce31e5`.
- Reviewer completed `BATCH-REV-005` in `72a4369` with verdict `changes requested`; only the Frontend pre-task cancel endpoint is misaligned with Backend's canonical route.
- Frontend completed `BATCH-FE-009` in `f644539`.
- Reviewer approved `BATCH-REV-006` in `e07e1e8`; PM marks the upload/status follow-up fixes ready for integration.
- User testing after integration commit `dcda349` found rotated preview reliability, upload timeout duration, and queued status copy issues; PM assigned `BATCH-FE-010` and `BATCH-REV-007`.
- User added two `BATCH-FE-010` requirements: upload timeout retries max 2 and final status must show insufficient polaroid count after all processing finishes.
- User added completed-processing action requirements to `BATCH-FE-010`: show `全部下载` and `删除全部图片`, and preserve failed source images when clearing.
- Reviewer first approved the rotation/timeout/queue/action scope in `b315634`, then requested changes in `1873ae9` for the remaining final shortage-status blocker.
- Frontend completed `BATCH-FE-011` in `e3488e3` and `b698c4b`.
- Reviewer approved `BATCH-REV-008` in `1ee2872`; PM marks the rotation/timeout/action and shortage-status fixes ready for integration.
- PM drew and user confirmed mini/wide image-area masks before publishing size-support tasks.
- PM assigned `SIZE-BE-001`, `SIZE-FE-001`, and `SIZE-REV-001` for mini/wide/auto polaroid size support.
- Frontend completed `SIZE-FE-001` in `86ddbe2`.
- Backend completed `SIZE-BE-001` in `ff9851a`.
- Reviewer approved `SIZE-REV-001` in `85a7ed4`; PM marks polaroid size support ready for integration.
- User testing after size support found four regressions: final status must list every insufficient-count image, post-completion navigation must not delete extracted results, `wx.uploadFile` socket/TLS failures must not leave the UI stuck in upload state, and the completed clear action should read `新任务`.
- PM assigned `BATCH-FE-012`, `BATCH-BE-004`, and `BATCH-REV-009` in Frontend, Backend, Reviewer order.
- User requested postprocessing modes based on `C:\Users\20888\Desktop\cheki\POSTPROCESSING.md`, count-input layout adjustment, and an `izaya7` token-page route.
- PM assigned `POST-FE-001`, `POST-BE-001`, and `POST-REV-001` in Frontend, Backend, Reviewer order.
- User added that fixed-border white balance should be performed in linear RGB space; PM folded this into `POST-BE-001` and `POST-REV-001`.
- User testing in real WeChat found that Add image can open the album and then fail after selecting an image before the mini program adds it.
- PM assigned `PICK-FE-001` and `PICK-REV-001`; Backend has no picker task because the failure occurs before upload/backend APIs.
- PM wrote `docs/agents/handoffs/2026-06-21-main-sync-briefing.md` so Frontend, Backend, and Reviewer understand the large `origin/main` navigation/calendar/map update now present in every worktree.
- Reviewer approved `PICK-REV-001` in `fabafd7`; Frontend picker fix commit is `506cf46`.
- User testing found two lifecycle/download issues: returning from background can redirect to auth and lose extraction content, and backgrounding during download can silently lose some saved images.
- User added a New Task preservation rule: if a source image's extracted polaroids were all not downloaded/saved or any failed, keep that source image and its extracted results.
- PM assigned `STATE-FE-001` and `STATE-REV-001`; Backend has no lifecycle/download task unless PM reopens API scope.
- User clarified token policy for `STATE-FE-001`: once auth-page verification succeeds and enters index, index must not re-verify token; only settings manual token clear should end the authenticated scanner flow.
- User clarified completed-state single-image delete behavior for `STATE-FE-001`: deleting a selected source image should remove only that image and its extracted results, without checking download/save status.
