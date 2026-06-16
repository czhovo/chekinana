# Taskboard

## Current Objective

Implement V1 batch image processing for the WeChat mini-program: users can select up to 9 images, add more images later, manage the selected-image list, enter per-image polaroid counts and rotations, then process each selected image in order and display all extracted polaroids in stable order.

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
```

## Worktree Assignments

| Role | Worktree | Branch | Task |
|---|---|---|---|
| PM | `C:\Users\20888\Desktop\chekinana-pm` | `codex/pm-next` | Maintain taskboard, contract, scope, and readiness decision only |
| Frontend | `C:\Users\20888\Desktop\chekinana-frontend` | `codex/frontend-next` | Implement batch selection, per-image controls, sequential processing, and ordered result aggregation |
| Backend | `C:\Users\20888\Desktop\chekinana-backend` | `codex/backend-next` | Verify existing single-image API supports V1 batch orchestration and make only necessary compatibility fixes |
| Reviewer | `C:\Users\20888\Desktop\chekinana-reviewer` | `codex/reviewer-next` | Review Frontend/Backend diffs against this taskboard and the agreed V1 behavior |

## Current Tasks

| ID | Owner | Status | Task | Files | Acceptance Criteria |
|---|---|---|---|---|---|
| BATCH-FE-001 | Frontend | review | Replace the single-image selection state with a selected-images list while preserving the existing single-image workflow. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-17-frontend-batch-images.md` | Frontend commits `94471d5` through `9865fe4` implement selection up to 9, add-more behavior, and selected-image state. Reviewer found remaining Frontend UI blockers listed in `BATCH-FE-005`. |
| BATCH-FE-002 | Frontend | review | Implement current-image preview management for multiple selected images. | Same Frontend files and same handoff as `BATCH-FE-001` | Frontend implements one large current-image preview, left/right navigation, delete-on-preview, index clamping, and thumbnail strip. Reviewer/user found remaining navigation/thumbnail UI blockers listed in `BATCH-FE-005`. |
| BATCH-FE-003 | Frontend | review | Bind polaroid count and rotation to the current image. | Same Frontend files and same handoff as `BATCH-FE-001` | Reviewer mock checks passed for independent per-image count and rotation state; no blocker currently assigned to this behavior. |
| BATCH-FE-004 | Frontend | review | Process selected images sequentially and aggregate ordered results. | Same Frontend files and same handoff as `BATCH-FE-001` | Reviewer mock checks passed for sequential processing, partial success, all-failed behavior, selected-image order, and task-scoped result keys. |
| BATCH-BE-001 | Backend | done | Audit and verify that the existing single-image backend task API safely supports V1 sequential batch orchestration. | `docs/agents/handoffs/2026-06-17-backend-batch-images.md` | Backend commit `d1af90d` adds a handoff only; no backend code changes. Reviewer confirmed existing API/rate-limit behavior supports normal 9-image sequential batches and no new batch API is needed. |
| BATCH-REV-001 | Reviewer | done | Review the batch image implementation after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-17-reviewer-batch-images.md` | Reviewer commit `99e8ba4` verdict: changes requested. Core batch logic and Backend compatibility are acceptable, but Frontend has blocking UI issues. |
| BATCH-FE-005 | Frontend | pending | Fix remaining batch UI blockers from Reviewer and user visual feedback. | `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `wechat-miniprogram/pages/index/index.js` only if needed for thumbnail tap behavior, `docs/agents/handoffs/YYYY-MM-DD-frontend-batch-ui-fixes.md` | Fix all three UI issues: (1) reset/constrain native `.tool-button` defaults so `添加图片` and `开始提取` fit cleanly without oversize or overflow; (2) replace the preview left/right navigation text so it renders correctly in the mini-program while preserving `catchtap` navigation; (3) shrink/reflow the thumbnail strip so all 9 selected images can be visible, and allow tapping a thumbnail to jump to that image. Fix must stay scoped to batch UI; do not change Backend, auth, upload sequencing, polling, result download, contact-author, or processing pipeline behavior. |
| BATCH-REV-002 | Reviewer | pending | Re-review the batch UI fixes after the Frontend handoff is available. | Review only; write `docs/agents/handoffs/YYYY-MM-DD-reviewer-batch-ui-fixes.md` | Reviewer verifies the two original P2 findings and the user-added thumbnail issue are resolved, no new UI regressions are introduced, all 9 thumbnails can be displayed and tapped to navigate, and the already-reviewed batch processing semantics remain intact. |

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

## Open Questions

- None. Reviewer findings and user-added thumbnail requirement are concrete Frontend fixes.

## Completed Work Summary

- PM discussed and captured the agreed V1 batch design before publishing this taskboard.
- Frontend implemented V1 batch behavior through `9865fe4`.
- Backend verified existing single-image API support in `d1af90d` without backend code changes.
- Reviewer completed `BATCH-REV-001` in `99e8ba4` with verdict `changes requested` for Frontend UI issues.
