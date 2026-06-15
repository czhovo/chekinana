# Worktree Workflow

Use one git worktree per agent. Do not let multiple agents work in the same checkout.

## Directory Layout

Recommended local layout:

```text
C:\Users\20888\Desktop\chekinana                 # integration worktree
C:\Users\20888\Desktop\chekinana-pm              # PM worktree
C:\Users\20888\Desktop\chekinana-backend         # Backend worktree
C:\Users\20888\Desktop\chekinana-frontend        # Frontend worktree
C:\Users\20888\Desktop\chekinana-reviewer        # Reviewer worktree
```

## Branch Naming

Use `codex/` branches:

```text
codex/pm-<task-slug>
codex/backend-<task-slug>
codex/frontend-<task-slug>
codex/reviewer-<task-slug>
```

Example:

```text
codex/pm-local-backend
codex/backend-local-backend
codex/frontend-local-backend
codex/reviewer-local-backend
```

## Create Worktrees

Run from the integration worktree:

```powershell
git fetch origin
git worktree add -b codex/pm-local-backend ..\chekinana-pm main
git worktree add -b codex/backend-local-backend ..\chekinana-backend main
git worktree add -b codex/frontend-local-backend ..\chekinana-frontend main
git worktree add -b codex/reviewer-local-backend ..\chekinana-reviewer main
```

If documentation or taskboard changes are not committed yet, either commit them first or copy the updated `docs/agents/` files into each worktree before starting agents.

## Agent Rules

- Each agent works only in its assigned worktree.
- Each agent commits only to its own branch.
- Frontend and Backend do not push directly to `main`.
- PM does not implement code unless explicitly assigned.
- Reviewer is read-only by default.
- Handoffs are written in the agent's worktree under `docs/agents/handoffs/`.

## Coordination Flow

1. PM updates taskboard in the PM worktree.
2. PM commits taskboard changes on `codex/pm-<task-slug>`.
3. Integration owner brings PM docs into the integration branch or shares the updated taskboard with other worktrees.
4. Backend and Frontend implement on their own branches.
5. Backend and Frontend commit their code and handoff files.
6. Reviewer reviews the integration diff or the relevant agent branches.
7. PM records reviewer verdict.
8. Integration owner merges or cherry-picks approved commits into `main`.

## Useful Commands

List worktrees:

```powershell
git worktree list
```

Remove a completed worktree:

```powershell
git worktree remove ..\chekinana-frontend
git branch -d codex/frontend-local-backend
```

If a branch must be kept for audit, do not delete it.

## Handoff Expectations

Each implementing agent should commit its handoff with its code changes:

```text
docs/agents/handoffs/YYYY-MM-DD-role-taskid.md
```

Reviewer should refer to exact branch names and commit hashes in the review handoff.
