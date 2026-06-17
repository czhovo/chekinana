# Taskboard

## Current Objective

Fix batch completion and upload-error regressions found during mini-program testing after mini/wide/auto size support. The fixes must aggregate all insufficient-count images in the final status bar, keep extraction results intact when navigating after completion, handle transient `wx.uploadFile` socket/TLS failures through the bounded upload failure path, and rename the completed clear action to `新任务`.

Scope constraints:

- Use the agreed V1 approach: no new batch backend API unless Backend finds a blocker.
- Frontend submits selected images sequentially to the existing `/api/process` single-image task API.
- Preserve token/auth behavior, RunPod startup, SAM/extraction internals other than output-size handling, result download auth, and existing single-image behavior.
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
```

## Worktree Assignments

| Role | Worktree | Branch | Task |
|---|---|---|---|
| PM | `C:\Users\20888\Desktop\chekinana-pm` | `codex/pm-next` | Maintain taskboard, contract, scope, and readiness decision only |
| Frontend | `C:\Users\20888\Desktop\chekinana-frontend` | `codex/frontend-next` | Own `BATCH-FE-012`: batch completion status/navigation/action copy and upload socket/TLS failure handling |
| Backend | `C:\Users\20888\Desktop\chekinana-backend` | `codex/backend-next` | Own `BATCH-BE-004`: verify backend compatibility for upload socket/TLS failure and existing cancel/status contracts |
| Reviewer | `C:\Users\20888\Desktop\chekinana-reviewer` | `codex/reviewer-next` | Own `BATCH-REV-009`: review Frontend fix and Backend compatibility handoff |

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
| BATCH-FE-012 | Frontend | pending | Fix batch completion status, post-completion navigation, completed action copy, and upload socket/TLS failure handling. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss` if needed, `docs/agents/handoffs/2026-06-18-frontend-completion-upload-regressions.md` | Final batch status must list every image whose extracted count is lower than its user-entered expected count, with per-image labels and received/expected counts when available. After extraction completes, tapping left/right preview navigation or thumbnails must only switch the current preview image and must not clear/delete extracted results, partial results, failed source-image markers, completed status, or completed action state. The screenshot upload failure `uploadFile:fail Error: Client network socket disconnected before secure TLS connection was established` must flow through the existing 15-second, max-2-retry upload failure path without an infinite `图片上传中` state, stale late-callback mutation, or raw low-level TLS copy in the status bar. After completion, the former `删除全部图片` action text must become `新任务`; its behavior remains the existing completed-task reset/clear-successful-images behavior, preserving failed source images when any exist. `全部下载` must continue downloading all extracted polaroids. Do not regress per-image `polaroid_size`, rotation, thumbnails, active-task queue/processing status, `/api/upload-cancel/<upload_attempt_id>`, `/api/cancel/<task_id>`, result ordering, shortage counts, contact flow, or auth. Handoff must include `node --check`, `git diff --check`, and mocked/manual evidence for multiple shortages, post-completion navigation preserving results, TLS/socket upload failure retry/failure handling, `新任务` label/behavior, failed-source preservation, and all-download behavior. |
| BATCH-BE-004 | Backend | pending | Verify backend compatibility for upload socket/TLS failures and current batch status/cancel contracts. | `docs/agents/handoffs/2026-06-18-backend-upload-failure-compat.md`; backend files only if a real backend blocker is found | Confirm whether the screenshot error can occur before Backend receives a request; if so, no Backend code change is required and the handoff should say that explicitly. Reconfirm existing `/api/process`, `/api/status/<task_id>`, `/api/result/<task_id>/<result_id>`, `/api/cancel/<task_id>`, and `/api/upload-cancel/<upload_attempt_id>` behavior still supports the Frontend fix, including late canceled uploads and active-task status. Do not change RunPod startup, production pod ID token flow, auth, result routes, mini/wide/auto geometry, contact email behavior, or extraction internals unless the audit proves a backend defect. If code changes are needed, include focused tests or smoke evidence and document the compatibility impact. |
| BATCH-REV-009 | Reviewer | pending | Review `BATCH-FE-012` and `BATCH-BE-004` after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-18-reviewer-completion-upload-regressions.md` | Verify all four user-reported issues: all insufficient-count images appear in final status, post-completion left/right and thumbnail navigation does not delete extraction results, the screenshot socket/TLS `wx.uploadFile` failure follows the bounded retry/failure/cancel path without stale mutation, and the completed action label is `新任务`. Also verify failed source images are preserved by the new-task/reset action when failures exist, `全部下载` still covers all extracted results, active-task queued/processing status still works, per-image mini/wide/auto size uploads still work, and no Backend auth/RunPod/contact/result/cancel regression is introduced. Required checks include Frontend `node --check`, `git diff --check`, Backend compatibility evidence or smoke checks from `BATCH-BE-004`, and explicit mocked/manual coverage for the screenshot error text. |

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

Frontend request flow:

- For each selected image, submit one `POST /api/process` request with multipart field `image`.
- Submit images sequentially in selected-image order.
- Include existing form fields per image:
  - `token`
  - `wb`
  - `denoise`
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

## Open Questions

- None. The user-reported regression set has concrete Frontend, Backend, and Reviewer owners; Backend work is a compatibility audit unless it discovers a real backend defect.

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
