# Taskboard

## Current Objective

Settings hidden route entry relocation is approved: `lianliankan` and `izaya7-map` are reached from Settings buttons, not auth token input.

Scope constraints:

- Frontend owns the implementation: add two Settings buttons that navigate to `pages/lianliankan/lianliankan` and `pages/izaya7-map/izaya7-map`.
- Auth token input must no longer accept `lianliankan` or `izaya7` as special route triggers; both values should follow the normal token validation path and fail unless they are real backend tokens.
- Preserve the normal backend token authentication flow, stored-token behavior, manual clear-token behavior in Settings, and scanner lifecycle behavior from `STATE-FE-001`.
- Preserve the newly synced `lianliankan` page registration, worker registration, tile assets, and the existing `izaya7-map` page.
- Backend has no implementation scope unless Frontend finds a concrete API or auth-contract blocker; Backend must still read the sync handoff and provide a no-code compatibility handoff so Reviewer understands the current codebase changes.
- Reviewer must review the Frontend diff plus the Backend no-code compatibility handoff and must verify that no backend API/auth route contract was changed.
- Use the agreed V1 approach: no new batch backend API unless Backend finds a blocker.
- Frontend submits selected images sequentially to the existing `/api/process` single-image task API.
- Preserve token/auth behavior, RunPod startup, SAM/extraction internals other than output-size handling, result download auth, and existing single-image behavior.
- Preserve white-balance behavior as a separate switch; postprocessing mode controls only denoise/sharpen after perspective warp and optional white balance.
- Batch result order must be: selected image order, then detected polaroid order inside each image.
- Continue processing later images if one image fails; report partial failures clearly.
- Maximum selected images: 9.
- Do not delete photos already saved to the user's system album; only delete mini-program local files created or referenced by the scanner flow.
- Keep immediate result download/display behavior; cache cleanup is tied to explicit source-image removal through `新任务` or manual source-image delete.
- Preserve local-cache cleanup from `CACHE-FE-001`: removing a source-image group still deletes its source/result local files.
- Do not add Backend API scope unless Frontend finds a concrete result URL/status contract blocker.
- Backend geometry cleanup must preserve current output sizes and masks: mini `1200x1908` with image area `[[82,150],[1118,150],[1118,1533],[82,1533]]`; wide `2400x1908` with image area `[[82,150],[2318,150],[2318,1533],[82,1533]]`.
- Save-state refresh fix must keep album-written as an irreversible local truth for the active result set: status polling, receiving a new extracted result, finishing single/batch processing, and background predownload completion may upgrade state but must not downgrade `album` to `downloaded` or `remote`, and must not downgrade `downloaded` to `remote` when a local path is still known.

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
Frontend lifecycle/download state fix commit: 0808fbe
Reviewer lifecycle/download state approval commit: f10daa1
User-reported large-result download/upload exhaustion: 2026-06-21 after about 40 extracted results are downloaded, later result downloads fail and new image uploads also fail; the earlier image upload failure symptom may share this cause; restarting the mini program or WeChat does not restore the flow.
User-directed RESULTDL implementation constraints: 2026-06-21 reject lazy/LRU/cleanup-based behavior changes that delay result display or discard completed images; reduce Backend mini output width from 1600 to 1200; Backend must return each extracted polaroid immediately after extraction; Frontend must download and display each returned result immediately; Frontend must keep completed-size downloaded images until the mini program exits or the user manually deletes the result through New Task or source-image deletion; upload timeout max retries becomes 3; index empty-preview helper adds `单次处理的拍立得数量不应超过50张`.
Reviewer RESULTDL changes-requested commit: b774fb2; Backend passed, Frontend blocker is failed result downloads being requeued by later status/prefetch passes after `downloadStatus=failed`.
User-directed local-cache cleanup constraint: 2026-06-21 WeChat mini-program local files are limited to about 200 MB, which is not enough for a normal high-count task if deleted images/results remain cached; when a source image is removed by `新任务` cleanup or manual source-image deletion, Frontend must immediately delete the source image file and that source's extracted result files from mini-program local storage.
Frontend local-cache cleanup commit: 7a9b81f
Reviewer local-cache cleanup approval commit: 403cf53
Integration push: 9a4b311 main includes approved local-cache cleanup work and taskboard completion status
User-reported save-state issue: 2026-06-23 result thumbnails can display before local download is complete; about one third of manually tapped saves still need seconds of remote download; all-download can stay in `保存中...` for minutes until WeChat download/save APIs fail; after manually saving all visible results to album, `新任务` can still preserve some source groups as not fully saved.
User-directed SAVE requirements: 2026-06-23 mark each extracted result's top-right corner with three distinct states: yellow circle for not downloaded to Frontend, green circle for downloaded to Frontend, green check for written to album; add timeout/retry/failure-skip behavior for both all-download and manual single-result save; ensure album-write success is correctly and durably recorded; `新任务` must decide cleanup based on whether every result in a source-image group has been written to the user's album.
User-directed geometry cleanup requirement: 2026-06-23 PM must not directly modify code; Backend must remove obsolete old output-size parameters `800` and `1600` from runtime geometry calculation, directly write the current mini/wide output dimensions and image-area coordinates into code, and provide two visual artifacts showing mini and wide image areas for user confirmation before integration.
Reviewer save-state approval commit: 48f00c3; reviewed Frontend implementation commit `9df106e`, cherry-picked as `e6858ca`, verdict approved.
Reviewer direct-geometry approval commit: b180ae7; reviewed Backend implementation commit `92036c4`, cherry-picked as `03f8cf1`, verdict approved.
Integration push: 822b51c main includes approved save-state and direct-geometry work.
User-reported SAVE refresh regression: 2026-06-23 after each newly received extracted polaroid causes the result area to refresh, previously green downloaded dots and green album checks can both reset to yellow remote-only circles; after a few seconds some items become green downloaded again, but album-written check state is lost.
Reviewer save-state refresh approval commit: 07d2644; reviewed Frontend implementation commit `37b43b0`, cherry-picked as `cba7352`, verdict approved.
Lianliankan direct sync handoff: 2026-06-25 `docs/agents/handoffs/2026-06-25-lianliankan-page-sync.md`
Direct sync changes currently present in all worktrees: new `wechat-miniprogram/pages/lianliankan/`, new `wechat-miniprogram/workers/`, `wechat-miniprogram/app.json` page/worker registration, `wechat-miniprogram/pages/auth/auth.js` temporary `lianliankan` special token branch, and removal of old `wechat-miniprogram/pages/izaya-map/`.
Frontend settings hidden route commit: ee9d792
Backend settings hidden route no-code handoff commit: 2991858
Reviewer settings hidden route changes-requested commit: 6751bab
Reviewer settings hidden route approval commit: ad09f8d
```

## Worktree Assignments

| Role | Worktree | Branch | Task |
|---|---|---|---|
| PM | `C:\Users\20888\Desktop\chekinana-pm` | `codex/pm-next` | Maintain taskboard, contract, scope, and readiness decision only |
| Frontend | `C:\Users\20888\Desktop\chekinana-frontend` | `codex/frontend-next` | `ROUTE-FE-001` completed in `ee9d792`; Reviewer applied authorized whitespace-only fix |
| Backend | `C:\Users\20888\Desktop\chekinana-backend` | `codex/backend-next` | `ROUTE-BE-001` completed in `2991858` as no-code compatibility handoff |
| Reviewer | `C:\Users\20888\Desktop\chekinana-reviewer` | `codex/reviewer-next` | `ROUTE-REV-001` completed with verdict: approved |

## Current Tasks

| ID | Owner | Status | Task | Files | Acceptance Criteria |
|---|---|---|---|---|---|
| ROUTE-FE-001 | Frontend | done | Move `lianliankan` and `izaya7-map` entry points from auth token input to Settings buttons. | `wechat-miniprogram/pages/settings/settings.js`, `wechat-miniprogram/pages/settings/settings.wxml`, `wechat-miniprogram/pages/settings/settings.wxss` if needed, `wechat-miniprogram/pages/auth/auth.js`, `wechat-miniprogram/app.json` only if route registration needs repair, `docs/agents/handoffs/2026-06-25-frontend-settings-hidden-routes.md` | Frontend commit `ee9d792` moves the hidden entries to Settings and removes auth shortcuts; Reviewer applied a one-time authorized whitespace-only fix so `git diff --check` passes. |
| ROUTE-BE-001 | Backend | done | Read the lianliankan sync handoff and the Frontend route-entry handoff, then confirm Backend has no implementation scope. | `docs/agents/handoffs/2026-06-25-lianliankan-page-sync.md`, `docs/agents/handoffs/2026-06-25-frontend-settings-hidden-routes.md`, `docs/agents/handoffs/2026-06-25-backend-settings-hidden-routes.md` | Backend commit `2991858` confirms no Backend code changes are required; Reviewer verified no Backend implementation or deployment-path files changed in this task. |
| ROUTE-REV-001 | Reviewer | done | Review the hidden-route entry relocation after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-25-reviewer-settings-hidden-routes.md` | Reviewer verdict: approved. Settings routes, auth shortcut removal, app/page/worker registration, Backend no-code scope, and required checks all passed after the authorized whitespace-only fix. |
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
| STATE-FE-001 | Frontend | done | Preserve extraction state across background/auth lifecycle and track download/save failures. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml` if UI state is needed, `wechat-miniprogram/pages/index/index.wxss` if needed, `docs/agents/handoffs/2026-06-21-frontend-lifecycle-download-state.md` | Frontend commit `0808fbe` stops scanner `onShow` from re-verifying stored tokens, still redirects when no local token exists, adds per-result album-save status (`unknown`, `saving`, `saved`, `failed`), surfaces partial all-download failures in the status bar, makes single-result save failures update the same tracking, preserves unsaved/failed/unknown source-image groups when tapping `新任务`, and implements completed-state manual source-image delete with result/failed-index reindexing. Upload/process/status/cancel contracts, picker behavior, `postprocess_mode`, `polaroid_size`, rotation, and main-sync routes remain unchanged. |
| STATE-REV-001 | Reviewer | done | Review `STATE-FE-001` after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-21-reviewer-lifecycle-download-state.md` | Reviewer verdict: approved. Reviewer confirmed no Backend/API scope was added; foreground return no longer calls `/api/auth/verify`, missing-token redirect and manual clear-token behavior still work, scanner state is preserved across foreground return, all-download and single-result save failures update visible save state, `新任务` preserves unsaved/failed/unknown groups and remaps source indexes, completed-state single-image delete removes only that source group while preserving/reindexing the rest, picker behavior still works, and main-sync tab/calendar/`izaya7-map` routes remain intact. Checks passed: `node --check`, `git diff --check`, and targeted lifecycle/download mocks. |
| RESULTDL-FE-001 | Frontend | done | Preserve immediate result download/display while adapting to 1200-width outputs and upload retry/text changes. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss` if needed, `docs/agents/handoffs/2026-06-21-frontend-large-result-downloads.md` | Frontend commit `86ea23a` implements immediate display with `localPath || url`, eager bounded result downloads with 3 active downloads, retained `localPath`/download status across duplicate result merges, upload max retries of 3, and the `单次处理的拍立得数量不应超过50张` helper line. Its original failed-download requeue blocker from reviewer commit `b774fb2` is resolved by `RESULTDL-FE-002` and approved by `RESULTDL-REV-002`. |
| RESULTDL-BE-001 | Backend | done | Reduce output size to 1200-width mini while preserving immediate incremental result availability. | `backend/app.py`, `scripts/check_polaroid_size.py` or focused equivalent, `docs/agents/handoffs/2026-06-21-backend-large-result-downloads.md` | Backend commit `6717034` reduces mini output to `1200x1908`, wide output to `2400x1908`, recomputes image-area vertices from the existing border proportions, preserves mini/wide/auto semantics, keeps per-polaroid `add_intermediate(...)` availability, and leaves result/status/process routes unchanged. Reviewer checks passed for geometry, explicit/auto size outputs, postprocessing compatibility, 60-result status metadata, result ids `0`, `39`, `40`, `59`, and a fresh `/api/process` upload after high-count result downloads. |
| RESULTDL-REV-001 | Reviewer | done | Review exact RESULTDL behavior after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-21-reviewer-large-result-downloads.md` | Reviewer verdict: changes requested. Backend passed the 1200/2400 geometry, immediate availability, high-count result route, fresh-upload, postprocessing, compile, and diff checks. Frontend passed positive checks for immediate display, bounded 3-active downloads, retained local paths, upload max retries of 3, late tap failure status, and helper text, but has a blocking failed-download requeue bug: a result marked `downloadStatus=failed` is queued again on later status/prefetch passes. |
| RESULTDL-FE-002 | Frontend | done | Stop failed eager result downloads from being requeued by later status/prefetch passes. | `wechat-miniprogram/pages/index/index.js`, focused mock/test if present, `docs/agents/handoffs/2026-06-21-frontend-result-download-requeue.md` | Frontend commit `b46f215` fixes the Reviewer P1 from `b774fb2`: passive eager result prefetch now skips results already marked `downloadStatus=failed`, so later duplicate status merges or `prefetchResultImages(...)` calls do not enqueue the same result again with a fresh eager retry budget. Explicit user intent remains preserved because tapping the failed result still starts the manual save/download path. |
| RESULTDL-REV-002 | Reviewer | done | Re-review failed-download requeue fix after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-21-reviewer-result-download-requeue.md` | Reviewer verdict: approved. Reviewer polling confirmed Frontend completed `b46f215` and Backend had no follow-up task. Checks passed for the fixed failed-download requeue mock, positive 45-result immediate-display/3-active-download regression mock, upload max retries of 3, helper text, backend 60-result route/fresh-upload smoke, 1200/2400 size geometry, postprocessing compatibility, `node --check`, `python -m py_compile`, and `git diff --check`. |
| CACHE-FE-001 | Frontend | done | Delete mini-program local files for removed source-image groups. | `wechat-miniprogram/pages/index/index.js`, `docs/agents/handoffs/2026-06-21-frontend-local-cache-cleanup.md` | Frontend integration commit `7a9b81f` implements best-effort local file cleanup for removed source-image groups: `新任务` cleanup deletes files for groups it clears, completed-state manual source-image deletion deletes exactly that source group, pre-processing source delete cleans the selected file path, source/result path cleanup is de-duplicated, pending download bookkeeping for removed results is cleared, and album photos are not deleted. |
| CACHE-REV-001 | Reviewer | done | Review local file cleanup after Frontend handoff is available. | Review only; `docs/agents/handoffs/2026-06-21-reviewer-local-cache-cleanup.md` | Reviewer integration commit `403cf53` verdict: approved. Reviewer confirmed source and result local-file cleanup, `新任务` preservation rules, manual source-image delete reindexing, pre-processing source delete cleanup, best-effort failure handling, no system-album deletion, no Backend/API changes, no regression to immediate display/download concurrency/failed-download non-requeue, and required checks. |
| SAVE-FE-001 | Frontend | done | Make result download/save state visible and reliable, and harden all-download plus single-result save. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, focused mock/test if present, `docs/agents/handoffs/2026-06-23-frontend-result-save-state.md` | Frontend commit `9df106e` implements and Reviewer commit `48f00c3` approves: result cards show yellow remote-only, green downloaded, and green-check album-written states; manual single-result save and all-download have bounded retry/timeout/failure-skip behavior; all-download continues after failures and reports partial failure; successful album writes are durable and not downgraded by later callbacks; `新任务` judges cleanup by album-written truth, preserving unsaved/failed groups and clearing fully saved groups through the existing local-cache cleanup path. |
| SAVE-REV-001 | Reviewer | done | Review result save-state badges, timeout/retry/skip behavior, and `新任务` album-write judgment after Frontend handoff. | Review only; `docs/agents/handoffs/2026-06-23-reviewer-result-save-state.md` | Reviewer commit `48f00c3` verdict: approved. Reviewer verified three badge states, remote-only not shown as downloaded, bounded single-save/all-download retry behavior, partial failure skip/reporting, album-write durability, `新任务` album-write cleanup decisions, local-cache cleanup for cleared groups, preservation/reindexing for unsaved groups, no Backend/API changes, and no regressions to ordering, immediate display, 3-active background predownload, failed-download non-requeue, source-image deletion, auth, picker, upload/cancel/status/result routes, postprocessing, or polaroid size. |
| GEOM-BE-001 | Backend | done | Remove obsolete base-size geometry scaling and write current mini/wide geometry directly. | `backend/app.py`, `scripts/check_polaroid_size.py` if needed, visual artifacts under `docs/agents/handoffs/` or linked from the Backend handoff, `docs/agents/handoffs/2026-06-23-backend-direct-polaroid-geometry.md` | Backend commit `92036c4` implements and Reviewer commit `b180ae7` approves: obsolete runtime geometry fields and constants such as `base_width`, `base_height`, `base_image_area_vertices`, `scale`, `BASE_POLAROID_W/H`, `POLAROID_SCALE`, and `BASE_IMAGE_AREA_VERTICES` are removed; mini is directly configured as `1200x1908` with `[[82,150],[1118,150],[1118,1533],[82,1533]]`; wide is directly configured as `2400x1908` with `[[82,150],[2318,150],[2318,1533],[82,1533]]`; white-balance border masking uses direct configured vertices and direct block/step values; mini/wide visual artifacts were generated and verified. |
| GEOM-REV-001 | Reviewer | done | Review direct polaroid geometry cleanup after Backend handoff. | Review only; `docs/agents/handoffs/2026-06-23-reviewer-direct-polaroid-geometry.md` | Reviewer commit `b180ae7` verdict: approved. Reviewer verified no obsolete `800`/`1600` runtime base-size geometry remains in `backend/app.py`, direct mini/wide dimensions and vertices match the accepted coordinates, white-balance mask uses direct geometry, visual artifacts are `1200x1908` and `2400x1908` and match the configured image areas, `py_compile`, `scripts/check_polaroid_size.py`, postprocessing checks, large-result route smoke, grep, pixel checks, and `git diff --check` passed, with no regressions to routes, auth, RunPod startup, task cancel, upload cancel, or Frontend API contracts. |
| SAVE-FE-002 | Frontend | done | Preserve result download/save state across status refreshes and newly received extraction results. | `wechat-miniprogram/pages/index/index.js`, focused mock/test if present, `docs/agents/handoffs/2026-06-23-frontend-save-state-refresh.md` | Frontend commit `37b43b0` implements and Reviewer commit `07d2644` approves: single-image polling refreshes, batch direct-result paths, batch polling paths, `finishBatchExtract(...)`, and background predownload completion preserve album-written `saveStatus=saved`, green-check `album` state, and known `localPath`; downloaded local-path results remain green downloaded when later backend payloads omit `localPath`; visible writes now merge through latest state rather than stale `baseImages`/`collectedImages`/accumulated arrays; `新任务` still uses album-written truth and keeps source indexes/order stable. |
| SAVE-REV-002 | Reviewer | done | Review save-state refresh durability after Frontend handoff. | Review only; `docs/agents/handoffs/2026-06-23-reviewer-save-state-refresh.md` | Reviewer commit `07d2644` verdict: approved. Reviewer verified single-image polling refresh, downloaded-local refresh persistence, batch direct-result and polling paths, stale accumulated arrays in `finishBatchExtract(...)`, background predownload after manual album save, `新任务` album-write cleanup decisions, source-image indexes, result ordering, manual single-result save, all-download timeout/retry/failure-skip behavior, and no Backend/API/auth/picker/upload/process/status/cancel/postprocessing/polaroid-size regressions. Checks passed: `node --check`, `git diff --check`, and targeted `SAVE-FE-002` refresh durability mock. |

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

Large-result output-size and immediate-delivery contract:

- The mini program must support downloading/saving result sets larger than 40 polaroids.
- User rejected lazy download, LRU eviction, delayed display, and active-session cleanup of completed result images.
- Backend mini completed output width must change from `1600` to `1200`; mini remains `1:1.59`, and wide remains two mini outputs side by side.
- Backend must treat the earlier border-proportion recomputation as superseded by `GEOM-BE-001`: current production geometry should directly configure the accepted current dimensions and image-area vertices, without deriving them from obsolete base output sizes.
- Backend must expose each extracted polaroid immediately after extraction through the existing status/result flow.
- Frontend must download each result immediately after receiving it and display it immediately in the extraction result area.
- Frontend must retain completed-size downloaded result images until the mini program exits or the user explicitly deletes the corresponding result through `新任务` cleanup or source-image deletion.
- When a source image is explicitly removed by `新任务` cleanup or manual source-image deletion, Frontend must immediately delete mini-program local files for that source image and every extracted result that belongs to that source. This is required because the mini-program local file budget is about 200 MB and normal high-count tasks can exceed it if deleted groups remain cached.
- Frontend should treat remote result URL download and album save as separate steps, preserving the per-result save state introduced by `STATE-FE-001`.
- Clicking a late result such as result 40+ must use a valid result URL and token, retry or fall back when safe, and show a specific visible error if the download truly fails.
- Downloading many results must not poison later upload/process attempts; after high-count result downloads, adding a new source image and starting a new upload must still work.
- Backend must keep `/api/status/<task_id>` result ids and `/api/result/<task_id>/<result_id>` downloads stable for high result counts; result ids 0, 39, 40, and a later id such as 59 should be covered by focused smoke where feasible.
- Backend must also show that a new `/api/process` upload is accepted after many result downloads, or identify and fix the server-side resource/connection issue that prevents it.
- Backend task cleanup or TTL must not delete completed task results before a normal user can download a large result set after processing completes.
- This task does not require a new zip/bulk-download API unless Backend/Frontend find the existing per-result route cannot be made reliable.

Local file cleanup contract:

- Deleting a source image before processing must remove the selected source image path from mini-program local files when the path is a deletable local/temp file.
- Manual completed-state source-image deletion must delete exactly that source image file and its extracted result files, regardless of result download/save status, while preserving all other source-image groups and reindexing their result metadata consistently.
- `新任务` keeps the existing save-state preservation rule: preserve source-image groups with failed source state or any unsaved/failed/unknown result; delete only the groups that the current `新任务` behavior is allowed to clear.
- For every source-image group that `新任务` clears, Frontend must also delete the source image local file and every downloaded extracted result local file belonging to that group.
- Result cleanup covers `localPath` values created by `wx.downloadFile` and result URLs that are already `wxfile://` local paths. Remote backend result URLs are not files and must not be treated as local cleanup targets.
- Source cleanup covers selected image `path` / `previewPath` values that are local temp files when they point at the same selected source; avoid double-deleting duplicate path references.
- Cleanup is best-effort: individual file deletion errors should be logged for debugging but must not block the visible delete/reset action.
- Cleanup must remove or ignore pending queued-download and active-download bookkeeping for deleted results so later callbacks/status merges do not restore deleted result state or enqueue deleted result downloads.
- Cleanup must not call any Backend API, change `/api/process`, `/api/status`, `/api/result`, auth, RunPod startup, postprocessing, `polaroid_size`, picker, or upload/cancel contracts.
- Cleanup must not delete photos already saved to the user's system album through `wx.saveImageToPhotosAlbum`.
- Exiting the mini program may still rely on WeChat/system cleanup; this task is only about immediate cleanup when the user explicitly removes source-image groups.

Result save-state contract:

- Every extracted result must expose three user-visible states on the result card's top-right corner:
  - yellow circle: not downloaded to Frontend; the result is only available by remote backend URL or is waiting/failed before local download.
  - green circle: downloaded to Frontend; a valid local mini-program file path exists, but the result has not been written to the user's album.
  - green check: written to the user's album; `wx.saveImageToPhotosAlbum` has succeeded for that exact result.
- A result being visible in the result grid is not sufficient to treat it as downloaded or album-saved.
- Frontend state must keep local-download state and album-write state separate; album-write success is the only success state used by `新任务`.
- Background predownload may still run after results arrive, but it must not overwrite a result that is already marked written to album.
- Manual single-result save and all-download must both use bounded timeout and retry behavior for remote result downloads and album writes.
- If a manual single-result save times out or fails after retry budget, the result must visibly remain not album-written and show a failure state/message without corrupting other results.
- If all-download times out or fails on one result after retry budget, it must mark that result failed/not album-written, skip it, continue later results, and show a final partial-failure summary.
- All-download must not stay indefinitely in `保存中...`; every per-result operation needs a completion path through success, failure, or timeout.
- `新任务` must preserve a source-image group if any extracted result in that group is not album-written.
- `新任务` may clear a source-image group only if every extracted result in that group is album-written, and clearing the group must retain the `CACHE-FE-001` behavior of deleting the source/result local files for that cleared group.
- The save-state UI and logic must not introduce new Backend API requirements.

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

- Existing output size is named `mini`, but RESULTDL changes its completed output width from `1600` to `1200`.
- `mini` ratio is `1:1.59`; updated output must be `1200x1908`.
- `wide` ratio is `2:1.59`; updated output must be `2400x1908`.
- The previous 0.75-scaled geometry guidance is superseded by `GEOM-BE-001`; Backend should not keep runtime scaling from old output-size parameters.
- Backend direct-geometry cleanup supersedes runtime old-size scaling: after `GEOM-BE-001`, production code should directly configure current output sizes and current image-area vertices, not derive them from old `800` / `1600` base output dimensions.
- The accepted direct coordinates for implementation and visual confirmation are mini `[[82,150],[1118,150],[1118,1533],[82,1533]]` and wide `[[82,150],[2318,150],[2318,1533],[82,1533]]`, matching the current checked script expectations.
- Backend must provide visual mini/wide artifacts showing the direct image-area coordinates before PM treats the geometry cleanup as ready for integration.
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
- Auth token input must not contain hidden page-entry shortcuts. Exact inputs `lianliankan` and `izaya7` must go through the same backend token validation path as any other non-token string and must not be stored as valid backend API tokens.
- Settings owns hidden/debug page entry points. It must expose one button for `/pages/lianliankan/lianliankan` and one button for `/pages/izaya7-map/izaya7-map`.
- The `izaya7-map` page navigation title remains `izaya7's map`.
- The newly synced `lianliankan` page, its worker dependencies under `wechat-miniprogram/workers/`, and the top-level worker registration in `app.json` must remain valid.
- This contract is Frontend-only. Backend `/api/auth/verify` semantics must not change for these strings.

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
- Upload timeout retry is capped at 3 retries per image upload attempt.
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
| 2026-06-21 | Reopen large-result download reliability as Frontend plus Backend audit. | User testing found downloads fail around the 40th result; Frontend has unbounded prefetch risk, while Backend must confirm result routes/TTL do not impose a hidden high-count limit. |
| 2026-06-21 | Clarify RESULTDL as a post-download exhaustion issue affecting downloads and uploads. | User clarified that after about 40 downloaded extraction results, later downloads fail and new image uploads also fail; the earlier upload failure may be the same issue, and restarting the mini program or WeChat does not recover. |
| 2026-06-21 | Use output-size reduction and preserve immediate result delivery/retention for RESULTDL. | User rejected lazy/LRU/cleanup behavior changes and required Backend 1200-width output, immediate per-polaroid return, immediate Frontend download/display, active-session retention of completed-size images, upload retries capped at 3, and the 50-polaroid guidance copy. |
| 2026-06-21 | Reopen RESULTDL Frontend for failed-download requeue after Reviewer changes requested. | Reviewer commit `b774fb2` found Backend passed, but Frontend can requeue a permanently failed eager result on later status/prefetch passes, recreating the resource-exhaustion risk. |
| 2026-06-21 | Deleted source-image groups must immediately release mini-program local files. | User clarified the WeChat mini-program local file budget is about 200 MB, which is not enough for a normal task if removed source images and extracted result files remain cached. |
| 2026-06-21 | Keep local-cache cleanup Frontend-only with Reviewer verification. | The files to delete are mini-program-selected source paths and `wx.downloadFile` result paths tracked in Frontend state; Backend result routes and processing contracts do not need to change. |
| 2026-06-23 | Expose three result states directly on result cards. | User testing showed result display can hide whether a polaroid is remote-only, downloaded locally, or already saved to album; each state must be visible with yellow circle, green circle, or green check. |
| 2026-06-23 | `新任务` cleanup must judge album-write state only. | User clarified that source-image cleanup should depend on whether every extracted result was written to the user's album, not whether it merely downloaded to the mini program. |
| 2026-06-23 | Add timeout/retry/failure-skip for all result save paths. | User testing found all-download can stay in `保存中...` for minutes until WeChat APIs fail, and manual single-result saves can wait on remote download; both paths need bounded behavior and reliable partial failure handling. |
| 2026-06-23 | Keep save-state fixes Frontend-only with Reviewer verification. | The problem is mini-program UI state, local download/album-save tracking, and WeChat API timeout handling; Backend result routes remain unchanged unless Frontend finds a concrete blocker. |
| 2026-06-23 | Remove obsolete polaroid geometry base-size scaling from Backend. | User clarified the old `800` and `1600` output-size parameters should be fully discarded from runtime code, with current geometry coordinates written directly instead. |
| 2026-06-23 | Backend must provide mini/wide coordinate visualizations for PM confirmation. | User requested two images showing the mini and wide image areas so the written coordinates can be visually confirmed before integration. |
| 2026-06-23 | PM must not modify business code directly. | User explicitly corrected the workflow: code changes must be assigned to role agents; PM coordinates through taskboard and readiness decisions only. |
| 2026-06-23 | Save-state and direct-geometry work are approved by Reviewer. | Reviewer commits `48f00c3` and `b180ae7` have approved verdicts; PM marks `SAVE-FE-001`, `SAVE-REV-001`, `GEOM-BE-001`, and `GEOM-REV-001` done and ready for user-directed integration. |
| 2026-06-23 | Reopen save-state work for refresh durability. | User testing after integration found that newly received extracted results can refresh the list and downgrade green downloaded or green-check album badges back to yellow; this remains Frontend-only because Backend result routes do not know album-write state. |
| 2026-06-23 | Save-state refresh durability is approved by Reviewer. | Reviewer commit `07d2644` approved Frontend commit `37b43b0`; PM marks `SAVE-FE-002` and `SAVE-REV-002` done and ready for local integration. |
| 2026-06-25 | Move hidden page entrances from auth token input to Settings. | User requested `lianliankan` and `izaya7-map` to be reachable through Settings buttons and no longer through special token strings in auth. |
| 2026-06-25 | Keep the route-entry change Frontend-owned with Backend no-code context handoff. | The synced `lianliankan` page and existing `izaya7-map` are mini-program pages; Backend only needs to confirm no server auth/API contract changes are required so Reviewer can evaluate the current codebase state. |

## Open Questions

- None. `ROUTE-REV-001` is approved after the one-time authorized whitespace-only fix in `wechat-miniprogram/pages/lianliankan/lianliankan.wxss`.

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
- Reviewer approved `STATE-REV-001` in `f10daa1`; Frontend lifecycle/download fix commit is `0808fbe`.
- User testing found a new high-count result download issue: after about 40 extracted polaroids, later result taps show download failed.
- PM assigned `RESULTDL-FE-001`, `RESULTDL-BE-001`, and `RESULTDL-REV-001` in Frontend, Backend, Reviewer order.
- User clarified the `RESULTDL` issue is broader: after about 40 downloaded extraction results, later downloads and new uploads fail, the previous upload failure may be caused by the same exhausted/stuck state, and restarting the mini program or WeChat does not recover.
- User directed the RESULTDL implementation strategy: reduce Backend mini output width from 1600 to 1200, preserve immediate per-result Backend availability and Frontend immediate download/display, retain completed-size images during the active mini-program session until explicit deletion, cap upload retries at 3, and add the 50-polaroid guidance line under the empty-preview helper.
- Reviewer completed `RESULTDL-REV-001` in `b774fb2` with verdict `changes requested`: Backend commit `6717034` passed, Frontend commit `86ea23a` has a P1 failed-download requeue blocker.
- PM assigned `RESULTDL-FE-002` and `RESULTDL-REV-002` for the remaining failed-download requeue fix and re-review.
- User clarified that the mini-program local file budget is about 200 MB and normal tasks can exceed it if deleted files remain cached.
- PM assigned `CACHE-FE-001` and `CACHE-REV-001`: when `新任务` or manual source-image deletion removes a source-image group, Frontend must immediately delete that source image file and its extracted result local files from mini-program local storage.
- Frontend completed local-cache cleanup in integration commit `7a9b81f`.
- Reviewer approved local-cache cleanup in integration commit `403cf53`.
- Integration `main` was pushed to GitHub at `9a4b311` with the approved local-cache cleanup work and taskboard completion status.
- User testing found that result display does not distinguish remote-only, downloaded-to-Frontend, and written-to-album states; tapping single results can still need seconds of download, all-download can stay in `保存中...` for minutes, and `新任务` can preserve groups even after the user manually saved visible results to album.
- PM assigned `SAVE-FE-001` and `SAVE-REV-001` for visible three-state result badges, bounded timeout/retry/failure-skip save behavior, durable album-write recording, and `新任务` cleanup decisions based only on album-write state.
- User clarified that PM must not directly modify code and all code changes should be assigned to role agents.
- PM assigned `GEOM-BE-001` and `GEOM-REV-001`: Backend must remove obsolete `800`/`1600` base-size scaling from polaroid geometry, directly write current mini/wide dimensions and image-area coordinates, and provide mini/wide visual artifacts for confirmation; Reviewer must verify the diff, artifacts, and regression checks.
- Reviewer approved `SAVE-REV-001` in `48f00c3`; Frontend save-state implementation commit is `9df106e`.
- Reviewer approved `GEOM-REV-001` in `b180ae7`; Backend direct-geometry implementation commit is `92036c4`.
- User testing after integration found a save-state refresh regression: receiving later extraction results can reset prior result badges from green downloaded or green-check album to yellow remote-only, and later predownload can restore only green downloaded while losing album-written state.
- PM assigned `SAVE-FE-002` and `SAVE-REV-002` for Frontend to make downloaded/album-written result state durable across all extraction refresh paths and for Reviewer to verify the stale-array/status-refresh regression.
- Reviewer approved `SAVE-REV-002` in `07d2644`; Frontend save-state refresh implementation commit is `37b43b0`.
- A direct sync added the completed `lianliankan` mini-program page, worker files, route registration, and a temporary auth special input for `lianliankan` across all worktrees; PM recorded the sync handoff and assigned `ROUTE-FE-001`, `ROUTE-BE-001`, and `ROUTE-REV-001` to move both `lianliankan` and `izaya7-map` entrances into Settings and remove auth shortcuts.
- Frontend completed `ROUTE-FE-001` in `ee9d792` and Backend completed `ROUTE-BE-001` in `2991858`; Reviewer initially requested changes for a `git diff --check` EOF blank-line failure, then applied the user-authorized whitespace-only fix and approved `ROUTE-REV-001`.
