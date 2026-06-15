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
Reviewer correction commit: f0af0dd
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
| CONTACT-FE-001 | Frontend | review | Replace the current single-line `wx.showModal` contact prompt with an in-page/custom modal containing a multi-line message input and a separate optional one-line contact input. | `wechat-miniprogram/pages/index/index.js`, `wechat-miniprogram/pages/index/index.wxml`, `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/2026-06-16-frontend-contact-dialog.md` | Frontend commit `cede97a` implements the dialog and request payload, but reviewer found a blocking visual/layout issue in the bottom action buttons. |
| CONTACT-BE-001 | Backend | done | Extend `/api/contact` handling so optional contact info is accepted, validated, and included in the email body without changing existing response shape. | `backend/app.py`, `docs/agents/handoffs/2026-06-16-backend-contact-dialog.md` | Backend commit `0e634c3` matches the API contract: `message` required, optional trimmed `contact` max 200, compatible response shape, unchanged auth/rate-limit behavior. Reviewer found no Backend blocker. |
| CONTACT-REV-001 | Reviewer | done | Review the contact dialog UI/API change after Frontend and Backend handoffs are available. | Review only; `docs/agents/handoffs/2026-06-16-reviewer-contact-dialog.md`, `docs/agents/handoffs/2026-06-16-reviewer-contact-dialog-correction.md` | Reviewer final verdict in commit `f0af0dd`: changes requested. Blocking finding: native contact dialog buttons overflow the modal because default mini-program button width/margin/padding/`::after` styles are not reset inside the two-column action grid. |
| CONTACT-FE-002 | Frontend | pending | Fix the contact dialog bottom action button layout reported by Reviewer. | `wechat-miniprogram/pages/index/index.wxss`, `docs/agents/handoffs/YYYY-MM-DD-frontend-contact-button-fix.md` | The cancel and send buttons stay within the dialog on the reviewed viewport; native mini-program button defaults that affect width, margin, padding, and `::after` border are reset or otherwise constrained inside the contact dialog only; no Backend, auth, upload, polling, result download, or processing files change; Frontend handoff includes `node --check wechat-miniprogram\pages\index\index.js`, `git diff --check`, and visual/manual evidence or a precise limitation if DevTools screenshot is unavailable. |
| CONTACT-REV-002 | Reviewer | pending | Re-review the Frontend contact button layout fix after the Frontend handoff is available. | Review only; write `docs/agents/handoffs/YYYY-MM-DD-reviewer-contact-button-fix.md` | Reviewer verifies the P2 button overflow finding is resolved, the fix is limited to contact dialog frontend styling, API contract remains intact, and no unauthorized implementation changes are made by Reviewer. |

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
| 2026-06-16 | Assign button overflow fix back to Frontend only. | Reviewer found a visual/layout blocker in Frontend CSS; Backend/API behavior is already acceptable. |
| 2026-06-16 | Do not treat Reviewer commit `2ed6faa` as an implementation source. | Reviewer noted it was an unauthorized implementation attempt and reverted it; Frontend must make the actual fix in its own worktree. |

## Open Questions

- None. Reviewer provided the concrete Frontend CSS issue and owner.

## Completed Work Summary

- PM planning committed as `66261b3`.
- Frontend implemented contact dialog in `cede97a`.
- Backend implemented optional contact email payload in `0e634c3`.
- Reviewer correction commit `f0af0dd` requests Frontend button layout fix before approval.
