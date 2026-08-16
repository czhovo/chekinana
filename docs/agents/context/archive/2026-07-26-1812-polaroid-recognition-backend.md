## Current Goal

Implement and review the Backend/Worker half of the new Polaroid recognition
contract.

## Latest User Instructions

- Start implementation in the Backend ownership area.
- Accept only the input JPEG plus `ink=0|1`.
- Return Polaroid/ink artifact IDs, date/bbox, and pattern through the existing
  asynchronous Scanner API.
- Leave Frontend implementation to another agent.

## Repository State

- Work was performed in the existing `main` checkout from starting HEAD
  `cf9f752abdd2`.
- Local product changes remain uncommitted and unpushed.
- Pre-existing changes in the Worker README and Windows runbook were preserved.

## Active Architecture And Contracts

- Python performs SAM3 extraction, optional same-size ink generation, and
  pattern classification.
- Worker/Wrangler remains the only owner of Qwen credentials and date
  annotation.
- Python submits one authenticated internal metadata batch after artifacts are
  ready; Worker retrieves those artifacts from its already selected Scanner
  upstream and returns date/bbox annotations.
- Task status is pure, repeatable observation and never triggers Qwen work.
- A task is marked `done` only after every annotation is atomically installed;
  otherwise it becomes a stable `failed` task with a fixed error code.
- Internal batches support at most 64 results and execute artifact/Qwen work in
  waves of eight.

## Authoritative References And Routing

- Carried forward and updated:
  `docs/agents/prompts/frontend-polaroid-recognition-v1.md`.
  Read completely before Frontend work or API-contract review. Backend/Worker
  now implement it; Frontend does not.
- Carried forward:
  `docs/windows-lan-gpu-backend-troubleshooting.md`.
  Read completely for Windows local GPU Scanner/Wrangler operation.
- No previous authoritative reference was removed.
- The earlier proposed `pipeline=polaroid_recognition_v1` selector was retired
  because the user explicitly reduced the request to `image` plus `ink=0|1`.
  The contract document and current context now contain the replacement.

## Scope And Non-Goals

- Changed only Backend/Worker runtime, their focused tests, PM-owned contract
  and context documents, plus an ignored local launcher.
- Did not edit iOS, the historical mini-program, deployment configuration, or
  secrets.
- Did not invoke production RunPod, live Qwen, commit, push, or deploy.

## Current Changes

- Backend: `backend/app.py`, `backend/requirements.txt`,
  `backend/polaroid_recognition.py`,
  `backend/date_annotation_callback.py`,
  `backend/test_polaroid_recognition.py`.
- Worker: `cloudflare-worker/src/worker.js`,
  `cloudflare-worker/src/cheki-date-annotator.js`,
  `cloudflare-worker/test/scanner-recognition-status.test.js`.
- Contract/context:
  `docs/agents/prompts/frontend-polaroid-recognition-v1.md`,
  `docs/agents/context/current.md`, and this archive.

## Completed This Window

- Implemented the full server-side contract and focused regression coverage.
- Reworked the first design so status polling is idempotent and Qwen runs only
  once before task completion.
- Reworked the second design so nine or more valid results no longer fail at an
  artificial total ceiling, while retaining bounded concurrency and image size.
- Confirmed final Reviewer verdict `approved` with no findings or open
  questions.

## Pending Work

- Frontend implementation against the routed contract.
- Explicitly requested Windows GPU/Wrangler/Qwen end-to-end validation.
- Separate product decision on persistent ink/pattern data and Idol mapping.

## Subagent State

- Backend agent: completed.
- Reviewer: completed; final verdict `approved`.
- No active subagent remains.

## Verification State

- Backend unit tests: 10/10 passed.
- Worker tests: 312/312 passed.
- Python compile, Worker syntax checks, PowerShell AST parsing, and whitespace
  checks passed.
- External classifier assets loaded and a known classification sample passed.
- Live Qwen, GPU ink generation, production RunPod, and real-image end-to-end
  verification were not run.

## Risks

- External classifier assets and credentials must be configured at runtime.
- Live Qwen latency can exceed the bounded callback budget and produce the
  documented fixed failure.
- Frontend has not yet adopted the expanded result schema.

## External Archive Candidates

Keep the external recognition prototype, galleries, checkpoints, and local
credentials outside Git. They are runtime inputs, not repository artifacts.

## Resume Prompt

For Frontend work, read
`docs/agents/prompts/frontend-polaroid-recognition-v1.md` completely, assign only
`ios/Chekinana/**` to the Frontend owner, preserve the documented asynchronous
routes and pixel bbox, then obtain Reviewer approval.
