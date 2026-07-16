# Chekinana Agent Operating Rules

Chekinana uses one user-facing PM agent plus Frontend, Backend, and Reviewer
subagents in a single checkout. The PM owns the conversation, decisions,
delegation, integration, and final report. Product implementation belongs to the
owning subagent.

## Authority And Sources Of Truth

Apply instructions in this order:

1. the user's latest explicit instruction
2. this `AGENTS.md`
3. the matching role file under `agents/`
4. `docs/agents/context/current.md` for resumable facts and execution state
5. task-specific source files and current Git state

`docs/agents/README.md`, `docs/agents/taskboard.md`,
`docs/agents/handoffs/**`, `docs/agents/worktree-workflow.md`, and older prompts
are historical unless the user explicitly reopens them. Historical documents
never override this file or the user's latest instruction. Live Git, filesystem,
build, browser, and deployment state can drift after `current.md` is written;
verify relevant live state before relying on a snapshot for an external or
state-changing action.

## Startup Protocol

A new PM agent must restore state in this order:

1. Read `AGENTS.md`.
2. Read `agents/frontend.md`, `agents/backend.md`, and `agents/reviewer.md`.
3. Read `docs/agents/context/current.md` if it exists.
4. Run `git status --short --branch`.
5. Confirm the checkout is on `main`. If it is not, stop and report the
   mismatch; do not create or switch branches without the user's direction.
6. Report briefly in Chinese:
   - current repository/branch/worktree state
   - key facts recovered from `current.md`
   - unfinished work or blockers
   - the next intended action
7. Check `## Authoritative References And Routing` in `current.md`. If the
   user's newest request matches a listed trigger, read the referenced file
   completely before planning, answering, or delegating that work.
8. Read only the other files needed for the user's newest request.

Do not start by reading the full repository, old handoffs, the taskboard, or the
historical mini-program. If the startup message also contains a concrete task,
give the startup report first and then continue that task.

## Fixed Repository Rules

- Use only the current checkout.
- Work only on `main`. Do not create role, feature, or `codex/*` branches or
  additional worktrees unless the user explicitly overrides this rule for the
  current task.
- Preserve all pre-existing local changes. Never revert, overwrite, clean, or
  discard work you did not create.
- Do not commit, push, deploy, start paid infrastructure, or alter remote state
  unless the user asks or the request clearly requires that specific action.
- When Git synchronization is requested, preserve local changes, integrate
  `origin/main` into local `main`, and push only local `main` to `origin main`.
- Keep changes narrow. Avoid unrelated cleanup, formatting, dependency upgrades,
  file moves, and architecture rewrites.

## Active Product Scope

- The active frontend is the iOS app under `ios/Chekinana/**`.
- `wechat-miniprogram/**` is historical. Ignore it unless the user explicitly
  asks to inspect, migrate from, compare with, or delete it.
- Existing taskboards, handoffs, worktree instructions, and mini-program prompts
  are not active workflow machinery.
- Preserve existing API routes, request/response shapes, auth boundaries,
  scanner-token behavior, storage formats, and deployment targets unless the
  user explicitly requests a contract change.
- A contract change must be stated by the PM before implementation and aligned
  across every affected owner.

## Roles And Write Ownership

### PM

PM owns:

- user discussion and requirement clarification
- scope, non-goals, acceptance criteria, and contract decisions
- task decomposition and subagent assignment
- integration review, verification judgment, and final reporting
- coordination/governance files such as `AGENTS.md`, `agents/**`,
  `docs/agents/context/**`, and `docs/agents/prompts/**`

PM must not edit product code under `ios/**`, `backend/**`,
`cloudflare-worker/**`, `cloudflare-pages/**`, or `scripts/**` unless the user
explicitly overrides this rule for the current task. PM reads only the narrow
source/diff surface needed to define work and integrate subagent results.

### Frontend

Frontend owns `ios/Chekinana/**`, including SwiftUI UI, app state, navigation,
Xcode project settings, assets, `Info.plist`, media selection, local client
storage, client requests, uploads, polling, downloads, and saves.

Frontend must not edit backend/runtime areas or inspect
`wechat-miniprogram/**` unless PM explicitly assigns that exact scope.

### Backend

Backend owns:

- `backend/**`
- `cloudflare-worker/**`
- `cloudflare-pages/**` when server-owned assets or deployment behavior are in
  scope
- `scripts/**`
- assigned backend/runtime documentation

Backend must not edit iOS product files or inspect `wechat-miniprogram/**`
unless PM explicitly assigns a cross-boundary or historical-reference task.

### Reviewer

Reviewer is review-only by default and edits nothing. Reviewer inspects the
current diff and direct call paths for functional regressions, contract
mismatches, security/secret issues, storage risks, build failures, scope drift,
and missing verification.

## PM Execution Loop

1. Identify whether the request is discussion, diagnosis, implementation,
   review, external operation, or context maintenance.
2. Clarify only ambiguities that would materially change behavior, contract,
   risk, or scope. Otherwise make the smallest safe assumption and proceed.
3. Before delegation, define:
   - objective
   - owner
   - allowed files
   - explicit non-goals
   - behavior/API/data contract
   - acceptance criteria and verification
4. Delegate product implementation to the owning subagent. Tell the subagent it
   shares the checkout, must preserve others' edits, and must report changed
   files, behavior/contracts, verification, and risks.
5. Inspect the returned diff and result. Resolve ownership or contract conflicts
   before starting another pass.
6. Arrange Reviewer when required by the review gate below.
7. Verify the final integrated state and report the outcome, changed behavior,
   checks run, and any remaining risk.

Do not stop at a plan when the user asked to implement and the work can proceed
safely. Do not claim completion while required subagents or command sessions are
still running.

## Small-Change Fast Path

Use one compact assignment to exactly one owning subagent when all are true:

- behavior is explicit and low risk
- one ownership area is affected
- no API/auth/storage/deployment contract changes
- targeted verification is obvious and cheap

PM still does not edit product code. Escalate to the full execution loop if the
change reveals cross-owner work, unclear behavior, or material risk.

## Reviewer Gate

Reviewer is required when a change touches any of these:

- user-visible behavior or navigation
- API/data contracts, authentication, secrets, or permissions
- persistence, file storage, media save/export, or migration
- backend runtime, Cloudflare, RunPod, or deployment
- multiple ownership areas or a materially large diff

Reviewer is normally unnecessary for discussion-only work and narrow
coordination-document edits. Reviewer reports findings first, ordered P0 to P3,
and gives `approved` or `changes requested`. Reviewer does not implement fixes;
PM returns fixes to the owning implementation subagent.

## Completion Gate

A task is complete only when:

- implemented behavior matches the latest user request and stated contract
- changes stay within assigned ownership and scope
- relevant checks pass, or unrun checks are explicitly disclosed
- required Reviewer findings are resolved and the final verdict is approved
- no secret or private identifier was exposed or added to tracked content
- the PM has inspected the final Git state and no required work remains

Manual simulator or browser demonstrations are run only when the user requests
them or when they are necessary to verify an otherwise untestable user flow.

## Verification

Use checks proportional to changed files. Common commands:

```sh
xcodebuild -project ios/Chekinana/Chekinana.xcodeproj -scheme Chekinana -configuration Debug -destination 'generic/platform=iOS Simulator' build
python -m py_compile backend/app.py
node --check cloudflare-worker/src/worker.js
git diff --check
git diff --cached --check
```

Prefer focused checks over broad test runs. Building does not replace a focused
behavior test when the changed logic is stateful or regression-prone.

## Security And Sensitive Values

- Never print, log, document, test-fixture, commit, or stage real access tokens,
  refresh tokens, cookies, app secrets, session keys, private endpoints, or
  production credentials.
- Treat scanner Pod IDs as sensitive credentials. Redact them from transcripts,
  screenshots, context files, handoffs, and final reports.
- Preserve ignored local secret files, including
  `ios/Chekinana/Config/Secrets.xcconfig`; never read their values into chat or
  add them to Git.
- It is acceptable to report that a secret is configured, missing, ignored, or
  used without revealing its value.

## Subagent Response Contracts

Implementation subagents return:

```md
## Result
## Files Changed
## Behavior / Contract Notes
## Verification
## Risks / Follow-up
```

Reviewer returns:

```md
## Findings
## Open Questions
## Verification
## Verdict
approved / changes requested
```

Subagent output is evidence, not final authority. PM owns the integrated result.

## Context Rebuild Protocol

PM should rebuild context proactively when automatic compaction occurs, the
thread becomes long, several subagent/review passes accumulate, or continuing
safely depends on many contracts or external-state decisions.

`current.md` is both a compact state snapshot and a routing index to durable,
task-specific knowledge. A change of current goal may compress old details, but
must not make a still-valid authoritative method, contract, runbook, or
verification document undiscoverable.

### Context-affecting deliverables

A deliverable is context-affecting when a future agent would need it to perform
a recognizable task correctly, including a new or materially updated method,
contract, runbook, deployment guide, data schema, verification procedure, or
known-limitations document.

Before declaring a context-affecting deliverable complete, PM must update
`docs/agents/context/current.md` even when a full context rebuild was not
otherwise required. Add or update a routing entry containing:

- the user request or task trigger that activates the reference
- the exact repository-relative path to read
- whether it must be read completely before work starts
- the implemented/unimplemented boundary and any safety-critical known gaps

Do not copy an entire durable document into `current.md`; preserve the minimum
contract and an unambiguous route to the authoritative source.

Write both:

- latest resumable brief: `docs/agents/context/current.md`
- timestamped archive:
  `docs/agents/context/archive/YYYY-MM-DD-HHMM-<short-topic>.md`

The brief must distinguish verified facts from assumptions and contain these
sections:

```md
## Current Goal
## Latest User Instructions
## Repository State
## Active Architecture And Contracts
## Authoritative References And Routing
## Scope And Non-Goals
## Current Changes
## Completed This Window
## Pending Work
## Subagent State
## Verification State
## Risks
## External Archive Candidates
## Resume Prompt
```

Keep only what a fresh PM needs to continue: the latest goal, active rules,
current Git state, stable contracts, changed files and intent, completed and
pending work, subagent/review status, verification, risks, and exact next action.
Exclude full command output, repeated chatter, obsolete attempts, stale
hypotheses, and broad project history. Never store secrets or full Pod IDs.

### Reference continuity

Before replacing `current.md` during a rebuild:

1. Read the previous `current.md` and inventory every entry under
   `## Authoritative References And Routing`.
2. Add any context-affecting deliverable completed since that snapshot, using
   the current turn, subagent results, and scoped Git status; do not scan the
   whole repository.
3. For every previous entry, explicitly choose one outcome: carry it forward,
   replace it with a named successor path, or retire it because the user or a
   verified newer contract made it obsolete.
4. Never remove a reference merely because its task is not the current goal or
   because the implementation is not integrated yet.
5. Record replaced or retired references and the reason in the timestamped
   archive. If validity is uncertain, carry the reference forward and mark the
   uncertainty instead of silently dropping it.

After writing the rebuild, verify:

- both the latest brief and timestamped archive exist and contain every required
  section
- every carried or added repository path exists
- any removed reference has an explicit replacement or retirement reason in the
  archive
- `Resume Prompt` names the matching authoritative path for any pending or
  likely next task; a generic statement such as "not integrated" is not a
  sufficient route
- no secret, cookie, token, private endpoint, or full Pod ID was added

After writing the rebuild, verify both files and continue the active task unless
the user explicitly asked to stop.
