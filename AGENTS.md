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
4. task-specific source files and current Git state

`docs/agents/README.md`, `docs/agents/taskboard.md`,
`docs/agents/handoffs/**`, `docs/agents/worktree-workflow.md`, and older prompts
are historical unless the user explicitly reopens them. Historical documents
never override this file or the user's latest instruction. Verify relevant live
Git, filesystem, build, browser, and deployment state before an external or
state-changing action.

### Retired `current.md`

- `docs/agents/context/current.md` is permanently retired.
- Never read, inspect, search, diff, summarize, update, replace, regenerate, or
  otherwise use that file.
- Do not use it for startup recovery, routing, planning, handoff, context
  compaction, verification, or task completion.
- Its existing contents have no authority and may be stale. Leave the file
  untouched unless the user explicitly orders a one-time deletion of the file.
- Do not create a replacement current-state file under another name unless the
  user explicitly requests one.

## Startup Protocol

A new PM agent must restore state in this order:

1. Read `AGENTS.md`.
2. Read `agents/frontend.md`, `agents/backend.md`, and `agents/reviewer.md`.
3. Run `git status --short --branch`.
4. Confirm the checkout is on `main`. If it is not, stop and report the
   mismatch; do not create or switch branches without the user's direction.
5. Report briefly in Chinese:
   - current repository/branch/worktree state
   - unfinished work or blockers
   - the next intended action
6. Read only the other files needed for the user's newest request.

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

## 内存监控、Agent 通信与等待成本

- 适用于 PM、Frontend、Backend、Reviewer 及其他子 Agent。
- 除非用户明确要求，否则不进行内存监控、采样或周期性检查；不得在每轮开始、操作前后或等待期间自动运行 `memory-guard/guard.py check`。旧的默认监控、内存软暂停和自动恢复授权不再作为执行依据；未经新的明确要求，不登记内存暂停或自动恢复任务。
- 用户要求单次内存检查不等于授权持续监控，只执行明确指定的范围。
- 尽量减少 Agent 间消息和状态通信。PM 一次给出完整任务边界、约束、验收条件及返回要求；同一接收方的相关信息合并发送。
- 仅在完成、实质性阻塞、必要的决策或接口变化、影响其他 Agent 的新发现、用户修改要求时发送必要消息。禁止例行催进度、重复提醒、纯确认和无变化状态往返；不要为确认消息另发确认。
- 完全避免反复短时间等待：不得循环数秒或十秒级等待、立即状态查询，或反复搜索子 Agent 尚未写好的代码、列举尚未生成的报告来探测进度。
- 优先依赖完成通知或事件驱动等待；有独立工作先执行独立工作。确需有界等待时，使用工具与上级指令允许的较长窗口；超时本身不是发送消息或再做空探测的理由。
- 收到完成或实质变化通知后集中读取产物并验证，不要因无变化状态反复唤醒模型作相同决策。仍须履行必要验证、用户进度告知和完成责任，不得把减少通信作为漏审或提前结束的理由。

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

## Full Repository Review Protocol

Use this protocol only when the user explicitly requests a complete repository
or system-wide code review. The authoritative stage prompt templates are:

1. `docs/agents/prompts/full-code-review/01-architecture.md`
2. `docs/agents/prompts/full-code-review/02-module.md`
3. `docs/agents/prompts/full-code-review/03-cross-module-risks.md`
4. `docs/agents/prompts/full-code-review/04-executable-report.md`

These are four stage templates, not four review tasks. A complete review executes
as `1 architecture + N module + 1 cross-module + 1 report` tasks, where `N` is
the number of in-scope modules discovered by architecture review. The stages are
strictly ordered. Architecture review must finish before PM creates the module
review tasks. PM then instantiates `02-module.md` separately for every
`MODULE-ID`, filling in that module's exact files, entry points, flows,
contracts, risk hypotheses, and exclusions from the architecture result. One
module task must contain exactly one `MODULE-ID`; do not combine several modules
into a single review result. PM runs module tasks one at a time in the dependency
order produced by architecture review and records each result before starting
the next module, unless the user explicitly requests parallel module review.

Every module identified by the architecture inventory must have its own review
result or be explicitly marked out of scope by PM before cross-module review
starts. The executable report is produced only after cross-module review
finishes.

Before stage 1, PM states the review baseline, included roots, exclusions, and
whether uncommitted work is included. Unless the user says otherwise, review the
current checkout as read-only, include the active iOS, Backend, Cloudflare, and
runtime/script surfaces, preserve all local changes, and apply the existing
historical and secret-file exclusions in this document. A full review does not
authorize edits, commits, deployment, remote-state changes, or reading secret
values.

Each stage must pass its complete output to the next stage. Reviewers must verify
claims against current source and configuration rather than relying only on
earlier summaries. Findings require a concrete trigger, user or system impact,
root cause, exact repository-relative file and line evidence, severity, and
responsible owner. Hypotheses and unverified concerns must be labeled separately
and must not be counted as confirmed findings.

Module review is complete only when the architecture inventory has a separate
coverage entry and a separate stage-2 result for every in-scope module,
including an explicit reason for any skipped or partially reviewed surface.
Cross-module review must trace real end-to-end paths
and reconcile route, payload, auth, state, persistence, timeout, retry,
cancellation, and deployment assumptions across owners. It must merge duplicate
findings rather than inflate counts.

The final report must be executable. For every confirmed finding it provides an
owner, affected modules, ordered repair steps, acceptance criteria, focused
verification, dependencies, and blocking status. It also records the baseline,
coverage, checks run, checks not run, residual risk, and an `approved` or
`changes requested` verdict. Any confirmed unresolved P0, P1, or P2 finding
requires `changes requested`.

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

## Context And Handoff Documentation

- Do not maintain or consult `docs/agents/context/current.md`.
- Create or update durable task documentation only when the user explicitly
  requests that documentation.
- Automatic compaction, a long thread, subagent passes, or task completion do
  not authorize creating context snapshots, routing indexes, or timestamped
  context archives.
- When the user explicitly requests a handoff, write only the narrowly requested
  standalone handoff artifact and never route it through `current.md`.
