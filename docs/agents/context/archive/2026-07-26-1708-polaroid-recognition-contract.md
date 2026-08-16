## Current Goal

Archive the PM decision for the proposed Polaroid recognition v1 Scanner
contract and the Frontend implementation boundary.

## Latest User Instructions

The user requested a new flow based on an external recognition description.
Frontend results must contain the cropped Polaroid, optional ink image, date
and bbox, and pattern. Another agent will implement the Frontend from this
specification.

## Repository State

- Branch and remote relationship verified as `main` at `cf9f752abdd2`.
- Existing unrelated modified states were preserved.
- Only PM coordination/context documents were added in this pass.

## Active Architecture And Contracts

- Preserve the asynchronous Scanner routes.
- New multipart fields:
  `pipeline=polaroid_recognition_v1` and `ink=0|1`.
- Date and pattern recognition are mandatory for v1; ink is optional.
- Status JSON pairs one Polaroid artifact, an optional ink artifact, and
  recognition metadata.
- Images remain binary result downloads.
- bbox is returned in pixel coordinates with image dimensions and converted by
  Frontend to the existing normalized storage/UI representation.
- Old Worker `date_annotation=1` is not used by v1.

## Authoritative References And Routing

- Added and retained:
  `docs/agents/prompts/frontend-polaroid-recognition-v1.md`.
  Trigger: any Frontend implementation or review of the new recognition flow.
  Must be read completely. Implementation is pending; ink/pattern persistence
  is excluded.
- Added for continuity:
  `docs/windows-lan-gpu-backend-troubleshooting.md`.
  Trigger: Windows local Scanner/Wrangler operation or diagnostics.
  Must be read completely. It remains valid and is not replaced by v1.
- No previous `current.md` existed, so no routing entries were replaced or
  retired.

## Scope And Non-Goals

This archive records contract decisions only. It does not authorize or contain
product-code changes, deployment, secrets, permanent ink/pattern storage, or
automatic pattern-to-Idol mapping.

## Current Changes

- New Frontend contract prompt.
- New latest context brief.
- This timestamped archive.

## Completed This Window

- Fully read the user-supplied behavior description.
- Verified the prototype entry script's raw/ink classification and date paths.
- Verified ink output dimensions match the cropped Polaroid.
- Verified date failures map to null date/bbox and unknown people map to
  `unassigned`.
- Compared the proposal with current iOS, Worker, and Python contracts.
- Selected an additive versioned schema and wrote the Frontend assignment.

## Pending Work

- Backend/Worker implementation.
- Frontend implementation.
- Focused tests, builds, runtime integration, and Reviewer approval.
- Separate product/storage decision for ink and pattern persistence.

## Subagent State

No subagent was assigned during this PM contract-definition pass.

## Verification State

Direct source inspection completed. No product build was necessary because no
product code changed. Documentation validation remains part of the final PM
check.

## Risks

- Implementing Frontend before Backend could create a temporary contract gap.
- Treating pixel bbox as normalized would corrupt overlays and persisted data.
- Ink doubles some result payload and memory costs.
- Pattern identifiers are opaque and must not be treated as Idol IDs.

## External Archive Candidates

The external prototype directory is not imported. Its stable behavior contract
is summarized in the tracked Frontend prompt without local credentials,
private paths, or model assets.

## Resume Prompt

Read `docs/agents/prompts/frontend-polaroid-recognition-v1.md` completely before
implementing the new Frontend flow. Confirm the Backend schema first, preserve
Scanner auth and the existing normalized date persistence, keep ink/pattern
temporary, and obtain Reviewer approval.
