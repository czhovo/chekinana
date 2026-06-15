# Agent Collaboration Guide

This project uses a PM-led multi-agent workflow with one git worktree per agent:

- PM coordinates scope, task breakdown, ownership, handoff, and final merge decisions.
- Frontend implements WeChat mini-program UI, state, and client API behavior.
- Backend implements Flask APIs, RunPod/runtime behavior, processing pipeline, and server contracts.
- Reviewer inspects diffs and handoffs for regressions, contract mismatches, and missing verification.

See `docs/agents/worktree-workflow.md` for worktree setup and branch conventions.

## Workflow

1. User gives the task to PM in the PM worktree.
2. PM updates `docs/agents/taskboard.md`.
3. PM assigns narrow tasks to Frontend and Backend.
4. Frontend and Backend work in separate worktrees and branches.
5. Implementing agents change only assigned files, commit their work, and write a handoff.
6. Reviewer inspects actual diffs, taskboard, and handoffs.
7. PM decides whether more work is needed, then coordinates integration.

## Core Rules

- `docs/agents/taskboard.md` is the source of truth for current scope.
- Each agent must work in its own git worktree and branch.
- Do not expand requirements without PM approval.
- Do not modify another agent's area unless explicitly assigned.
- API contract changes must be documented before both sides implement against them.
- Preserve token/auth behavior unless the taskboard explicitly changes it.
- Keep changes narrow and avoid unrelated cleanup.
- Reviewers report findings; they do not implement unless PM reassigns the work.

## Ownership

Frontend owns:

- `wechat-miniprogram/pages/**`
- `wechat-miniprogram/utils/**`
- UI layout, mini-program state, request/polling/download/save behavior

Backend owns:

- `backend/**`
- `scripts/**`
- Flask endpoints, task state, RunPod startup, model processing, email sending

PM owns:

- `docs/agents/taskboard.md`
- task assignment and handoff routing
- final readiness decision

Reviewer owns:

- review notes and final verdict
- severity-ranked findings with file references

## Required Checks

Use the checks that match changed files:

```powershell
python -m py_compile backend\app.py
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\utils\config.js
git diff --check
```

## Handoffs

Each implementing agent writes a handoff under:

```text
docs/agents/handoffs/YYYY-MM-DD-role-taskid.md
```

Use `docs/agents/handoff-template.md`.
