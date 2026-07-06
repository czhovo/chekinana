# Agent Collaboration Model

This project uses a lightweight PM-led agent workflow.

The main agent acts as PM. The PM talks to the user, breaks requirements into
strictly scoped tasks, delegates implementation or review to subagents, and
integrates the results in the same checkout. Subagents do not coordinate through
separate worktrees or long handoff documents unless the PM explicitly asks for
that for audit reasons.

## Single Checkout / Main Branch Policy

Use only the current checkout for future work. Do not create, reuse, or depend
on separate PM, Frontend, Backend, or Reviewer worktrees.

Use only the `main` branch for local code changes, commits, and pushes. Do not
create feature branches or role branches unless the user explicitly overrides
this policy for a specific task.

When syncing with GitHub:

- fetch and merge/pull `origin/main` into the current `main`
- keep local changes in this checkout unless the user explicitly asks to discard
  them
- push completed work only to `origin main`
- treat older `codex/*`, role, or worktree branch guidance as historical context,
  not as the active workflow

If local or remote non-main branches are encountered, do not base new work on
them. Clean up local non-main branches when safe and ignore remote non-main
branches unless the user explicitly asks to delete them from GitHub.

## Roles

- PM: Owns user communication, scope control, task breakdown, API contracts,
  final integration decisions, and final reporting.
- Frontend subagent: Owns mini-program UI, page state, client requests, polling,
  downloads, saves, and frontend route behavior.
- Backend subagent: Owns server-side APIs, Cloudflare Worker services, storage,
  backend runtime behavior, processing contracts, and deployment-sensitive
  server configuration.
- Reviewer subagent: Reviews the current diff and direct call paths for
  regressions, contract mismatches, syntax/build failures, exposed secrets, and
  missing verification.

## Default Workflow

1. PM reads the user's request and identifies the smallest useful scope.
2. PM records the task boundary before delegating:
   - objective
   - owner
   - allowed files
   - explicit non-goals
   - API or data contract expectations
   - required verification
3. PM delegates to one or more subagents using the matching file under
   `agents/`.
4. Each subagent returns a concise result directly to PM:
   - files changed or reviewed
   - behavior/API changes
   - verification run
   - risks or follow-up
5. PM inspects results, resolves cross-role conflicts, and decides whether
   another subagent pass is needed.
6. Reviewer runs after implementation when the change touches user-visible
   behavior, shared contracts, auth/security, storage, deployment paths, or more
   than one ownership area.
7. PM sends the final user-facing summary only after implementation and
   verification are complete or a real blocker is identified.

## Scope Control Rules

- The user's latest request is the governing scope.
- Keep changes narrow. Do not perform unrelated cleanup, formatting, dependency
  upgrades, file moves, or architecture rewrites.
- Treat existing `docs/agents/taskboard.md` and handoffs as historical context,
  not as mandatory workflow machinery for new tasks unless PM explicitly reopens
  that process.
- Do not silently change API request shapes, response shapes, auth boundaries,
  storage formats, route names, or deployment targets.
- If a contract change is required, PM must state it before implementation and
  both Frontend and Backend must align on it.
- Preserve scanner token behavior unless the task explicitly changes scanner
  authentication.
- Preserve WeChat login/user-session behavior unless the task explicitly changes
  non-scanner identity.
- Never put secrets, private tokens, app secrets, session keys, refresh tokens,
  private endpoints, or production credentials in source, docs, logs, tests, or
  handoff text.

## Ownership Boundaries

Frontend may normally edit:

- `wechat-miniprogram/pages/**`
- `wechat-miniprogram/components/**`
- `wechat-miniprogram/utils/**`
- mini-program assets and configuration when the task requires route/UI changes

Backend may normally edit:

- `backend/**`
- `cloudflare-worker/**`
- `cloudflare-pages/**` when server-owned public assets or deployment behavior
  are part of the task
- `scripts/**`
- backend/runtime documentation when assigned

Reviewer may normally edit nothing. Reviewer reports findings. PM may explicitly
assign a tiny reviewer-side documentation or formatting fix, but review-only is
the default.

PM may edit coordination docs and may implement small changes directly only when
delegation would add overhead and the file ownership is unambiguous. For
cross-boundary work, PM should delegate.

## Required Verification

Run checks that match changed files. Common commands:

```sh
python -m py_compile backend/app.py
node --check wechat-miniprogram/pages/index/index.js
node --check wechat-miniprogram/pages/auth/auth.js
node --check wechat-miniprogram/pages/settings/settings.js
node --check wechat-miniprogram/utils/config.js
node --check cloudflare-worker/src/worker.js
git diff --check
```

Use focused scripts or mocks when available. Prefer low-cost targeted checks
over broad test runs unless the risk justifies a broader run.

## Subagent Response Format

Subagents should respond to PM with:

```md
## Result

## Files Changed Or Reviewed

## Behavior / Contract Notes

## Verification

## Risks / Follow-up
```

Reviewer should instead use:

```md
## Findings

## Open Questions

## Verification

## Verdict
approved / changes requested
```

## Integration Rule

PM is responsible for the final integrated state. A subagent's result is input,
not final authority. PM must verify that the final diff still matches the user's
scope and that no subagent changed another role's area without explicit
approval.

## Context Rebuild Protocol

The PM should proactively rebuild context when the thread becomes long, when a
task spans several files or subagents, when many decisions have accumulated, or
when continuing safely would require remembering a large amount of prior
conversation. Do not wait for automatic context compaction if a manual rebuild
would make the next steps safer.

The goal is to preserve stable facts and the current execution state, not to
carry every debug detail forward. Older decisions, obsolete attempts, command
transcripts, and detailed debug history should be moved to external storage when
they remain useful for audit. They should not be kept in the active rebuilt
context unless they directly affect the current task.

Suitable external storage includes:

- project docs under `docs/`
- task or review notes under `docs/agents/` when explicitly useful
- issue/PR comments when the work is GitHub-centered
- dedicated archive notes requested by the user

Do not store secrets or private credentials in any context rebuild or external
archive.

### When To Trigger

The PM may trigger a context rebuild without waiting for the user when any of
these are true:

- the conversation has accumulated many implementation decisions
- several subagent results or review passes must be kept aligned
- current work depends on API contracts, data shapes, auth boundaries, storage
  behavior, or deployment state established earlier
- the active diff is non-trivial and further work may continue in a later window
- debug history is large enough that it should be separated from current facts

### What To Keep In Active Context

Preserve only the information needed to continue correctly:

- current user goal and the latest user instruction
- current repository, branch, worktree, and git status
- current PM plan and task ownership
- active task boundaries, non-goals, and allowed files
- stable interface contracts, including request/response shapes, headers,
  route names, auth/session requirements, storage keys, and error semantics
- core architecture decisions that still govern the current work
- data structure definitions, schema fields, enum values, storage formats, and
  migration state relevant to current work
- critical constraints, including security, secret-handling, scanner-token,
  WeChat-login, RunPod, Cloudflare Worker, D1/R2/KV, and deployment boundaries
- files changed in the current window and the intent of each change
- commands already run and high-signal verification results
- completed tasks in the current window
- unfinished tasks, blockers, and exact next actions
- subagent assignments and subagent results that are still active
- known risks that affect the next action

### What To Exclude From Active Context

Do not keep these in the rebuilt active context unless they directly explain the
next action:

- full command output
- old failed approaches after the final decision is clear
- stale hypotheses
- repeated status chatter
- unrelated historical taskboard rows
- detailed debug logs that can be recreated or archived externally
- prior decisions that have been superseded
- broad project history not needed for the current task

### Rebuild Prompt

When rebuilding context, the PM should use this prompt:

```md
You are performing a manual context rebuild for the Chekinana PM-led agent
workflow.

Create a compact but complete continuation brief. Preserve stable facts and the
current execution state. Separate facts from assumptions. Keep only information
needed to continue the current work safely. Do not include long debug history,
obsolete attempts, or old decisions unless they directly constrain the next
action. If older details remain useful, name the external storage location where
they should be archived instead of copying them into active context.

Output the following sections:

## Current Goal
State the user's latest goal in one or two sentences.

## Latest User Instructions
List explicit instructions from the user that still govern the work.

## Repository State
Include repository path, branch, git status, relevant commits, and whether there
are uncommitted changes.

## Active Architecture And Contracts
Capture stable interface contracts, route names, request/response shapes,
headers, auth/session boundaries, storage behavior, schema/data structures,
deployment boundaries, and core architecture decisions that still matter.

## Scope And Non-Goals
State allowed files, owner boundaries, and what must not be changed.

## Current Changes
List files changed in this context window and the purpose of each change.

## Completed This Window
List completed tasks and verification already performed.

## Pending Work
List unfinished tasks, blockers, open questions, and exact next actions.

## Subagent State
Summarize active or completed Frontend, Backend, and Reviewer subagent
assignments and their results.

## Verification State
List commands run, results, and any important checks not yet run.

## Risks
List only risks that affect the next implementation, review, or deployment
step.

## External Archive Candidates
List older debug history, obsolete attempts, detailed logs, or superseded
decisions that should live outside active context, with suggested storage
locations.

## Resume Prompt
Write a concise prompt that a fresh PM agent can use to continue from this
state without rereading the full conversation.
```

### User Trigger Phrases

The user can trigger this protocol with any direct instruction such as:

- `执行上下文重构`
- `整理当前上下文`
- `生成继续执行摘要`
- `上下文快满了，先重构`
- `按 AGENTS.md 做 context rebuild`

After rebuilding context, PM should continue the current task unless the user
explicitly asks to stop.
