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
| BATCH-FE-001 | Frontend | pending | Replace the single-image selection state with a selected-images list while preserving the existing single-image workflow. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/YYYY-MM-DD-frontend-batch-images.md` | Users can select up to 9 images in one picker action; users can click the add button later to append more images up to 9; the old "选择图片" button becomes "添加图片"; the empty preview copy reflects adding/selecting images; adding more images keeps existing selected images and their per-image state; existing contact-author changes, auth, upload headers, result download, and save behavior are not regressed. |
| BATCH-FE-002 | Frontend | pending | Implement current-image preview management for multiple selected images. | Same Frontend files and same handoff as `BATCH-FE-001` | The preview frame still displays only one current image even when multiple images are selected; when more than one image exists, left/right edge controls switch to previous/next image; the current index is clamped after deletion; tapping a selected preview no longer opens replace choices and instead offers only a delete-image action; deleting the final image returns the page to empty/idle selection state. |
| BATCH-FE-003 | Frontend | pending | Bind polaroid count and rotation to the current image. | Same Frontend files and same handoff as `BATCH-FE-001` | The count label reads `图片n/m包含的拍立得数量`; count placeholder is `可选`; switching to an image with no count shows an empty input; each image retains its own count value; the rotate button affects only the current image; switching images shows that image's own rotation preview; upload form uses the current image's own `expected_polaroids`/`polaroid_count` and `rotation_degrees`. |
| BATCH-FE-004 | Frontend | pending | Process selected images sequentially and aggregate ordered results. | Same Frontend files and same handoff as `BATCH-FE-001` | Start extraction submits images one at a time to existing `POST /api/process`; no more than one backend task is actively uploaded/polled at once; if an image fails, Frontend records the failure and continues with the next image; final results are ordered by selected image index, then backend polaroid order within that image; result IDs/merge keys are unique across tasks, for example `taskId:resultId`; status text shows batch progress such as current image `n/m`, extracted count, and partial-failure summary; if all images fail or extract nothing, user sees a clear failure/notice. |
| BATCH-BE-001 | Backend | pending | Audit and verify that the existing single-image backend task API safely supports V1 sequential batch orchestration. | `backend/app.py`, `backend/config.json` only if a compatibility fix is necessary, `docs/agents/handoffs/YYYY-MM-DD-backend-batch-images.md` | Backend confirms existing `POST /api/process`, `/api/status/<task_id>`, and `/api/result/<task_id>/<result_id>` support repeated sequential submissions from one user; rate limit behavior is checked against the 9-image maximum and does not break a normal 9-image batch; per-image `expected_polaroids`/`polaroid_count`, `rotation_degrees`, `wb`, and `denoise` remain honored; no new API route is added unless explicitly justified in the handoff; RunPod startup, auth, SAM extraction internals, and result response shape remain unchanged. |
| BATCH-REV-001 | Reviewer | pending | Review the batch image implementation after Frontend and Backend handoffs are available. | Review only; write `docs/agents/handoffs/YYYY-MM-DD-reviewer-batch-images.md` | Reviewer verifies the agreed V1 design is implemented, max 9 selection is enforced, add/delete/navigation behavior works from code evidence, per-image count/rotation state is independent, sequential processing continues after individual failures, result ordering and unique result keys are correct, Backend contract/rate-limit checks are covered, and unrelated contact/auth/RunPod/processing behavior is not changed. |

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

## Open Questions

- None at assignment time.

## Completed Work Summary

- PM discussed and captured the agreed V1 batch design before publishing this taskboard.
