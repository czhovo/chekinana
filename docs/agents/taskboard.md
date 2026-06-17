# Taskboard

## Current Objective

Fix post-integration V1 batch image processing issues found during mini-program testing: rotated thumbnails must match the large preview, image upload must have bounded timeout/retry and cancel semantics even before a backend `task_id` exists, and queued/processing status must be driven by the backend's active processing task id instead of stale queue-position heuristics.

Scope constraints:

- Use the agreed V1 approach: no new batch backend API unless Backend finds a blocker.
- Frontend submits selected images sequentially to the existing `/api/process` single-image task API.
- Preserve token/auth behavior, RunPod startup, SAM/extraction internals, result download auth, and existing single-image behavior.
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
```

## Worktree Assignments

| Role | Worktree | Branch | Task |
|---|---|---|---|
| PM | `C:\Users\20888\Desktop\chekinana-pm` | `codex/pm-next` | Maintain taskboard, contract, scope, and readiness decision only |
| Frontend | `C:\Users\20888\Desktop\chekinana-frontend` | `codex/frontend-next` | Fix rotated thumbnails, upload timeout/retry, pre-task interrupt, and active-task-based status display |
| Backend | `C:\Users\20888\Desktop\chekinana-backend` | `codex/backend-next` | Expose active processing task id and support canceling/ignoring timed-out upload attempts before `task_id` exists |
| Reviewer | `C:\Users\20888\Desktop\chekinana-reviewer` | `codex/reviewer-next` | Review Frontend/Backend diffs against the new upload/status contract |

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
| BATCH-BE-003 | Backend | pending | Add backend support for active-task status and pre-task upload cancellation. | `backend/app.py`, `docs/agents/handoffs/2026-06-17-backend-upload-status-contract.md` | `/api/status/<task_id>` must include a clear field for the single worker's currently active processing task id, for example `active_task_id` or `processing_task_id`, plus existing `status`, `phase`, and `queue_position` fields. While a task is in SAM detection (`phase=detecting`) or extraction (`phase=extracting`), the active task id must match that task. When no task is actively processing, the field must be empty. Add a protected pre-task upload cancel mechanism keyed by a frontend-supplied upload attempt id, so if the user interrupts or an upload attempt times out before `/api/process` returns a `task_id`, the backend can record that upload attempt as canceled and reject/drop a late `/api/process` arrival without queuing or extracting it. Preserve existing `/api/cancel/<task_id>` semantics for queued/processing tasks, existing auth/token/rate-limit behavior, RunPod startup, extraction internals, and result endpoints. Handoff must document the exact new field names and cancel endpoint/request shape, plus mocked checks for active task id, queued task id mismatch, pre-canceled late upload, and normal upload compatibility. |
| BATCH-FE-008 | Frontend | pending | Fix thumbnails, upload timeout/retry, pre-task interrupt, and active-task-based status display. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-17-frontend-upload-status-fixes.md` | Thumbnail images below the large preview must use the same rotated preview source/state as the large preview, so every selected image's thumbnail reflects its per-image rotation. `wx.uploadFile` must be wrapped in a bounded timeout and retry flow with documented constants; on timeout, abort the current upload task if possible, mark that upload attempt canceled through the Backend pre-task cancel contract, retry only within the configured limit, and then fail or continue according to existing partial-failure batch behavior without leaving the UI stuck on `图片上传中`. If the user taps interrupt before a backend `task_id` exists, the frontend must abort the upload task when possible, send the pre-task cancel signal using the upload attempt id, stop further uploads, and ignore late callbacks. Once a `task_id` exists, keep calling `/api/cancel/<task_id>` as before. Queue display must use the backend active processing task id: show queued/waiting only when the backend reports another active task id for the current status response; when the active task id matches the current image's `task_id`, show `图片处理中` for loading/detecting phases and `正在提取第 x 张 (x/N)` for extraction progress, even before the first polaroid result arrives. Do not regress ordered results, incremental display, per-image count/rotation, interrupt/cancel for active tasks, auth, contact UI, or save/download behavior. Handoff must include `node --check`, `git diff --check`, and mocked checks for rotated thumbnails, upload timeout/retry, interrupt during upload before task id, late-upload cancellation, active-task queue detection, detecting phase status, extracting-first-result status, and normal sequential batch behavior. |
| BATCH-REV-005 | Reviewer | pending | Review `BATCH-BE-003` and `BATCH-FE-008` together after both handoffs are available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-upload-status-fixes.md` | Verify the three user-reported issues are resolved end to end: thumbnails rotate with the large preview, a stuck upload cannot leave the UI indefinitely in `图片上传中` and cannot later create an uncanceled backend extraction after the user interrupted, and queue/processing status follows the backend active task id rather than `queue_position: 0` or stale queued payloads. Reviewer must also check no RunPod/auth/result/contact behavior regressed and run the relevant backend static/mocked checks, frontend `node --check`, and `git diff --check`. |

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
  - optional `expected_polaroids`
  - optional `polaroid_count`
- Poll each returned `task_id` through existing `/api/status/<task_id>`.
- Download each result through existing `/api/result/<task_id>/<result_id>`.

Backend response contract:

- Existing `/api/process` response shape remains compatible.
- Existing `/api/status/<task_id>` fields remain compatible, including `results`, `expected_polaroids`, `total_polaroids`, `warning`, and `extraction_complete`.
- Existing `/api/result/<task_id>/<result_id>` behavior remains compatible.
- No new batch route is required for V1.

Ordering contract:

- Overall display order is selected image order.
- Within each image, display order is backend result order, which should remain the existing detected polaroid order.
- Frontend must use a result key unique across backend tasks, such as `taskId:resultId`, to avoid merging result `0` from different images.

Failure contract:

- A failed upload, failed task, timeout, or empty extraction for one image must not stop later images from processing.
- Final UI must distinguish full success, partial success, and no successful results.
- Interrupting a running batch must cancel the currently active backend task as well as stop the frontend batch flow.
- Frontend must call the Backend cancel endpoint for the active `task_id`, then stop further uploads and ignore/stop polling updates after the user interrupts.
- Backend cancellation should terminate queued tasks immediately and stop processing tasks as soon as practical through explicit cancel state checks; after cancellation it must not continue extracting additional polaroids for that task.
- Frontend must keep incremental result display: results returned during `/api/status/<task_id>` polling should appear immediately, not only after the whole source image completes.

Frontend preview/status contract:

- The preview for the selected image must render as the image in its current rotation state, not by applying a transient rotation transform to the preview frame that can affect the previously displayed image during image switches.
- Thumbnail previews must render from the same per-image rotated preview source/state as the large preview.
- Per-image rotation remains part of the existing upload contract through `rotation_degrees`; this task does not require backend API changes.
- Status text must distinguish these phases in order: upload (`图片上传中`), queued/waiting, processing/extracting, completed/partial/failed/canceled.
- Queued/waiting state must be derived from the backend's active processing task id for the current status response, not from `queue_position: 0` or from an initial queued upload response alone.
- If the backend reports that the active processing task id matches the current image's `task_id`, the frontend must show processing/detecting/extracting status for that image even if no polaroid result has been returned yet.
- If the backend reports another active processing task id, the frontend may show queued/waiting for the current image and include queue position when available.
- If no backend active processing task id is present and the current task is not yet active, the frontend should show backend waiting rather than incorrectly claiming another task is in the queue.

Upload timeout/cancel contract:

- Frontend must generate a unique upload attempt id for each image upload attempt and include it in the `/api/process` request.
- Backend must provide a protected way to record an upload attempt id as canceled before `/api/process` returns a `task_id`.
- If a late `/api/process` request arrives with an upload attempt id already marked canceled, Backend must not enqueue or extract that image.
- Frontend must abort timed-out or interrupted `wx.uploadFile` attempts when possible and send the pre-task cancel signal for the upload attempt id.
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

## Open Questions

- None. The new user-tested issues have concrete Backend, Frontend, and Reviewer owners.

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
