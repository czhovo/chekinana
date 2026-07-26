## Current Goal

Restrict the implemented Backend person classifier to `pattern1`–`pattern6`
while preserving the existing Polaroid, optional ink, date/bbox, and status
contract.

## Latest User Instructions

- Add the new processing flow to Backend and Worker.
- The request contract is `image` plus `ink=0|1`; do not add a pipeline selector.
- Return image artifact IDs plus `date`, pixel `bbox`, and `pattern` in task
  status.
- Keep the existing asynchronous Scanner routes and authentication boundary.
- Do not modify Frontend in this task.
- Only `pattern1`–`pattern6` may participate in classification; all other
  gallery classes must be ignored.

## Repository State

- Verified branch: `main`.
- Starting HEAD for this implementation window: `cf9f752abdd2`.
- `main` matched `origin/main` before implementation.
- Pre-existing modifications in `cloudflare-worker/README.md` and
  `docs/windows-lan-gpu-backend.md` remain preserved.
- Product changes are uncommitted and unpushed.

## Active Architecture And Contracts

- Scanner remains asynchronous:
  `POST /api/process -> GET /api/status/<id> -> GET /api/result/<id>/<result>`.
- `POST /api/process` accepts JPEG field `image` and `ink=0|1`.
- Python uses SAM3 for Polaroid extraction and optional same-size ink images,
  then classifies each result against the raw or ink gallery.
- Qwen credentials remain in Worker/Wrangler. Python sends one authenticated,
  metadata-only internal callback after all image artifacts are ready.
- Worker fetches artifacts only from the already selected fixed Scanner
  upstream, applies one date-rate-limit operation per task, and annotates
  results in waves of at most eight concurrent Qwen requests.
- Python publishes all date/bbox values atomically before changing the task to
  `done`; an annotation failure yields a stable, fixed-error `failed` task.
- Done status results contain `id`, `polaroid_result_id`, `ink_result_id`,
  `date`, pixel `bbox`, and `pattern`.
- `ink_result_id` is `null` when `ink=0`; `date` and `bbox` are both present or
  both `null`; unmatched patterns use `unassigned`.
- Pattern classification now considers only `pattern1`–`pattern6`. Gallery
  entries such as `pattern7`, `pattern9`, `pattern10`, `pattern11`, or unknown
  names never enter the similarity matrix. Status can therefore expose only
  `pattern1`–`pattern6` or `unassigned`.
- The legacy `date_annotation=1` path remains available for compatibility, but
  the new flow reads date metadata from task status.
- The internal annotation batch ceiling is 64 results, with at most eight
  artifact/Qwen operations live at once and a three-megabyte limit per image.

## Authoritative References And Routing

- Trigger: implementing or reviewing the Frontend for Polaroid image + optional
  ink + date/bbox + pattern results.
  Read completely:
  `docs/agents/prompts/frontend-polaroid-recognition-v1.md`.
  Boundary: Backend/Worker now implement this wire contract; Frontend is not
  implemented. Ink/pattern persistence remains explicitly excluded.
- Trigger: modifying or reviewing the recognition API, pattern/name mapping, or
  result-download behavior.
  Read completely:
  `docs/agents/prompts/frontend-polaroid-recognition-v1.md`.
  Boundary: the contract uses only `image` and `ink`; no pipeline selector is
  part of the implemented request. The authoritative pattern/name mapping is
  limited to `pattern1`–`pattern6`.
- Trigger: diagnosing or operating Windows local GPU Scanner/Wrangler.
  Read completely:
  `docs/windows-lan-gpu-backend-troubleshooting.md`.
  Boundary: documents the local proxy and `Expect` fix; current recognition
  runtime still requires configured classifier assets and an authenticated
  loopback callback.

## Scope And Non-Goals

- Implemented only Backend/Worker behavior and focused tests.
- No iOS files, historical mini-program files, deployment configuration,
  production infrastructure, or secrets were changed.
- No production RunPod, live Qwen, or paid infrastructure was invoked.
- No commit, push, or deployment was performed.
- Permanent iOS persistence for ink/pattern and mapping a pattern to an Idol
  remain outside this task.

## Current Changes

- Backend runtime:
  `backend/app.py`, `backend/requirements.txt`,
  `backend/polaroid_recognition.py`,
  `backend/date_annotation_callback.py`.
- Backend verification:
  `backend/test_polaroid_recognition.py`.
- Worker runtime:
  `cloudflare-worker/src/worker.js`,
  `cloudflare-worker/src/cheki-date-annotator.js`.
- Worker verification:
  `cloudflare-worker/test/scanner-recognition-status.test.js`.
- Contract:
  `docs/agents/prompts/frontend-polaroid-recognition-v1.md`.
- Local ignored launcher `.venv/run-backend.ps1` was updated to bind the
  callback and model assets without printing credentials; it is not tracked.
- Pre-existing README/runbook modifications remain present and must not be
  attributed to or discarded by this implementation.

## Completed This Window

- Added Polaroid extraction integration, optional ink generation, raw/ink
  gallery classification, artifact storage, and status metadata.
- Added a metadata-only internal date-annotation callback so Qwen secrets stay
  in Worker/Wrangler and repeated status polls remain side-effect free.
- Preserved local header-only token authentication, constant-time token checks,
  token/forwarding-header removal, fixed IPv4-loopback local upstream, and the
  existing production Scanner selection path.
- Removed the initial synchronous-on-status design after review.
- Removed the initial eight-result total ceiling after review; 64 results are
  accepted and processed in bounded waves of eight.
- Added tests for success, stable failures, authentication boundaries, unknown
  fields, duplicate identifiers, local/production upstream isolation, status
  idempotence, large batches, byte limits, and limiter behavior.
- Obtained final read-only Reviewer verdict: `approved`.
- Restricted raw and ink classification candidates to `pattern1`–`pattern6`
  by filtering gallery names and prototypes together before inference.
- Added defensive output allowlisting and fail-closed handling when a gallery
  has no allowed candidate.
- Added order-independent tests proving excluded patterns cannot win even when
  they have the highest similarity score.
- Obtained Reviewer approval for the classification restriction.

## Pending Work

1. Frontend owner may implement
   `docs/agents/prompts/frontend-polaroid-recognition-v1.md`.
2. Restart the currently running Python Backend before runtime use, then run a
   Windows GPU test to confirm live results cannot return an excluded pattern.
3. Decide separately whether ink and pattern should become persistent iOS
   fields or pattern should map to an existing Idol.

## Subagent State

- Backend implementation agent completed the pattern restriction and is idle.
- Reviewer approved the latest pattern restriction with no findings.
- No subagent is currently running.

## Verification State

- Backend unit tests: 13/13 passed in the project virtual environment.
- Worker tests: 312/312 passed.
- Python compilation, both Worker JavaScript syntax checks, PowerShell launcher
  AST parsing, and `git diff --check`: passed.
- Current raw/ink gallery and checkpoint assets loaded successfully using the
  project environment; one known sample classified to its expected pattern.
- Reviewer independently checked the 9-result bounded-concurrency regression,
  the 65-item early rejection, authentication, isolation, idempotence, and
  stable error behavior.
- Reviewer independently verified prototype/name alignment, arbitrary gallery
  order, exclusion of every non-allowlisted class, fail-closed empty filtering,
  and unchanged raw/ink grayscale behavior.
- Live Qwen, GPU ink generation, production RunPod, and a real two-photo
  end-to-end run were not executed in this implementation window.

## Risks

- Real GPU/Qwen latency and output quality remain runtime-verification items.
- The 480-second Python callback timeout is intentionally sized for up to eight
  sequential waves; slow external Qwen responses can still produce the fixed
  annotation-unavailable failure.
- Classifier galleries/checkpoints are external runtime assets and are not
  committed to the repository.
- Frontend remains incompatible with the expanded status schema until its
  routed implementation is completed.
- The currently running Python process predates the latest source change and
  must be restarted before the six-pattern restriction is active at runtime.

## External Archive Candidates

The user-supplied recognition description, prototype scripts, classifier
galleries, checkpoints, and local credentials remain outside the repository.
Do not copy model keys, local asset paths, private runtime configuration, or
task/result identifiers into Git.

## Resume Prompt

For Frontend implementation, read
`docs/agents/prompts/frontend-polaroid-recognition-v1.md` completely and
delegate only `ios/Chekinana/**` to the Frontend owner. Backend/Worker already
implement the documented schema; preserve the pixel-bbox contract, accept only
`pattern1`–`pattern6` or `unassigned`, and require Reviewer approval for the
user-visible/API integration.
