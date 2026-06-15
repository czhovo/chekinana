# Taskboard

## Current Objective

Update the WeChat mini-program contact-author experience so users can enter a multi-line message, optionally provide one-line contact information, and see a polished dialog that matches the app style.

Scope constraints:

- Do not change token/auth behavior.
- Do not change RunPod startup, backend processing, or image extraction behavior.
- Do not add phone/local-backend requirements.
- Keep the change limited to contact-author UI, request payload, and email handling.

## Current Workspace State

Required fields:

```text
Branch: codex/pm-next
Worktree: C:\Users\20888\Desktop\chekinana-pm
Git status: clean at task start
Relevant existing changes: none
Task branch names:
  PM: codex/pm-next
  Backend: codex/backend-next
  Frontend: codex/frontend-next
  Reviewer: codex/reviewer-next
```

## Worktree Assignments

| Role | Worktree | Branch | Task |
|---|---|---|---|
| PM | `C:\Users\20888\Desktop\chekinana-pm` | `codex/pm-next` | Maintain taskboard, API contract, and readiness decision only |
| Frontend | `C:\Users\20888\Desktop\chekinana-frontend` | `codex/frontend-next` | Build the custom contact dialog UI and send optional contact info |
| Backend | `C:\Users\20888\Desktop\chekinana-backend` | `codex/backend-next` | Accept optional contact info and include it in contact email |
| Reviewer | `C:\Users\20888\Desktop\chekinana-reviewer` | `codex/reviewer-next` | Review Frontend and Backend diffs against this taskboard |

## Current Tasks

| ID | Owner | Status | Task | Files | Acceptance Criteria |
|---|---|---|---|---|---|
| CONTACT-FE-001 | Frontend | pending | Replace the current single-line `wx.showModal` contact prompt with an in-page/custom modal containing a multi-line message input and a separate optional one-line contact input. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/YYYY-MM-DD-frontend-contact-dialog.md` | Message field supports and displays multiple lines; contact field is one line and optional; placeholder font size is smaller than body input text; dialog styling matches the existing mini-program visual language; empty message is rejected client-side; submit sends `{ message, contact }` to `/api/contact`; cancel/close resets transient dialog state; existing upload/process/result flows are unchanged. |
| CONTACT-BE-001 | Backend | pending | Extend `/api/contact` handling so optional contact info is accepted, validated, and included in the email body without changing existing response shape. | `backend/app.py`, `docs/agents/handoffs/YYYY-MM-DD-backend-contact-dialog.md` | `message` remains required and keeps the existing length limit; `contact` is optional, trimmed, and length-limited; email body includes contact info only when provided; existing auth/rate-limit behavior for `/api/contact` is unchanged; API response success/failure shape remains compatible with the current frontend; Backend handoff includes `python -m py_compile backend\app.py` and focused contact-route verification. |
| CONTACT-REV-001 | Reviewer | pending | Review the contact dialog UI/API change after Frontend and Backend handoffs are available. | Review only; write `docs/agents/handoffs/YYYY-MM-DD-reviewer-contact-dialog.md` | Reviewer verifies file boundaries, API contract alignment, no auth/token or unrelated processing changes, required checks, and that the UI supports multi-line message plus optional one-line contact input. |

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

`POST /api/contact` keeps the existing route, auth, rate limit, and response conventions.

Request JSON:

```json
{
  "message": "required non-empty string, existing max length remains 1000 characters",
  "contact": "optional string, trim before use, max length 200 characters"
}
```

Contract details:

- `message` is the multi-line content entered by the user.
- `contact` is optional one-line contact information such as WeChat ID, email, phone, or other preferred contact method.
- Missing or empty `contact` must be accepted.
- Backend must reject overlong `contact` with a clear 400 error.
- Backend success response remains compatible with the existing frontend success check, for example `{ "ok": true, "status": "sent" }`.
- Frontend must not change token storage, auth headers, API base URL behavior, upload, polling, result download, or save behavior.

## Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-06-16 | Use a custom mini-program dialog instead of `wx.showModal({ editable: true })`. | The platform modal supports only a single editable field and cannot satisfy multi-line plus optional contact input. |
| 2026-06-16 | Add optional `contact` as an explicit `/api/contact` JSON field. | Keeps user message and contact method semantically separate while preserving the existing route and response shape. |
| 2026-06-16 | Assign both Frontend and Backend tasks, then require Reviewer approval. | The change crosses UI and API/email handling, so both sides need a documented contract and review. |

## Open Questions

- None at assignment time.

## Completed Work Summary

- Not started.
