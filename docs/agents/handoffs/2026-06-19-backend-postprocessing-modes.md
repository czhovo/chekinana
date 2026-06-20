# Handoff

## From

Agent role: Backend

## Task ID

POST-BE-001

## Summary

Implemented Backend `postprocess_mode=off|denoise|sharpen`, LAB-channel postprocessing, and fixed-border white balance in linear RGB space.

## Files Changed

- `backend/app.py`
  - change: Added `postprocess_mode` parsing with `off`, `denoise`, and `sharpen` modes.
  - change: Preserved legacy `denoise` compatibility when `postprocess_mode` is absent.
  - change: Converted fixed-border white balance to select/average/apply gains in linear RGB, then convert back to sRGB `uint8`.
  - change: Replaced the old colored NLM denoise with conservative LAB-channel NLM.
  - change: Added reduced USM low sharpen on LAB `L` channel only.
  - change: Exposes normalized `postprocess_mode` and `white_balance_color_space` in `/api/process` response and `/api/status/<task_id>`.
- `scripts/check_postprocessing_modes.py`
  - change: Added focused mocked checks for parsing, linear-RGB white balance, off/denoise/sharpen steps, legacy compatibility, invalid fallback, API metadata, and auth baseline.
- `docs/agents/handoffs/2026-06-19-backend-postprocessing-modes.md`
  - change: Added this handoff.

## Behavior Changed

`POST /api/process` now accepts optional multipart field:

```text
postprocess_mode=off|denoise|sharpen
```

Mode behavior:

- `off`: skip denoise and sharpen after perspective warp and optional white balance.
- `denoise`: run LAB-channel NLM denoise only.
- `sharpen`: run LAB-channel NLM denoise first, then LAB `L`-only reduced USM sharpen.

Legacy behavior:

- If `postprocess_mode` is absent, legacy `denoise=0` maps to `off`.
- If `postprocess_mode` is absent, missing/true legacy `denoise` maps to `denoise`.
- If `postprocess_mode` is present but invalid, Backend falls back to `denoise`.

White balance:

- `wb` remains the only white-balance switch.
- `postprocess_mode=off` does not disable white balance.
- When `wb` is enabled, fixed-border white balance now uses `linear_rgb` for white-reference selection, averaging, and gain application, then converts back to sRGB `uint8`.
- The existing fixed-border reference-block strategy and mini/wide geometry masks are preserved.

Postprocessing parameters from `C:\Users\20888\Desktop\cheki\POSTPROCESSING.md`:

- LAB denoise: OpenCV `fastNlMeansDenoising`, L channel `h=3.5`, A/B channels `h=6.0`, `templateWindowSize=7`, `searchWindowSize=21`.
- LAB `L` sharpen: `sigma=1.0`, `amount=0.45`, `threshold=3.0`; A/B channels are left unchanged.

No intentional changes were made to RunPod startup, auth/token flow, task queue/cancel, result routes, mini/wide/auto geometry, the meaning of the `wb` switch, contact route, or SAM detection.

## API Contract Changes

Added request field:

```text
postprocess_mode=off|denoise|sharpen
```

Added response/status metadata:

```json
{
  "postprocess_mode": "off|denoise|sharpen",
  "white_balance_color_space": "linear_rgb"
}
```

`white_balance_color_space` is an empty string when `wb` is false. Existing `denoise` remains present for compatibility and is `false` only when the normalized mode is `off`.

## Verification

Commands run:

```text
git cherry-pick f369772
git cherry-pick 9706534
python -m py_compile backend\app.py scripts\check_postprocessing_modes.py scripts\check_polaroid_size.py
python scripts\check_postprocessing_modes.py
python scripts\check_polaroid_size.py
git diff --check
```

Results:

```text
py_compile: passed
scripts/check_postprocessing_modes.py: passed
- parse_postprocess_mode default/legacy/invalid behavior
- linear_rgb fixed-border white balance applies and returns uint8
- off leaves image unchanged
- denoise uses lab_fastNlMeansDenoising with L h=3.5 and AB h=6.0
- sharpen runs denoise then lab_l_channel_usm with sigma=1.0 amount=0.45 threshold=3.0
- /api/process rejects missing auth
- default request returns postprocess_mode=denoise
- legacy denoise=0 returns postprocess_mode=off and denoise=false
- invalid postprocess_mode returns denoise
- postprocess_mode=sharpen with wb=0 returns white_balance_color_space=""
- /api/status exposes postprocess_mode, white_balance, and white_balance_color_space
scripts/check_polaroid_size.py: passed
- mini/wide/auto geometry output checks still pass
- missing/invalid polaroid_size fallback still passes
git diff --check: passed
```

## Risks / Follow-up

- Local focused scripts mock torch, flask-cors, and scipy.spatial to avoid requiring the full model/runtime stack in this workstation.
- Reviewer should inspect visual output on representative real scans because conservative denoise/sharpen is intentionally subtle.

## Notes For Next Agent

- Frontend should send `postprocess_mode=off|denoise|sharpen`; it can keep sending legacy `denoise` during transition.
- The Frontend `POST-FE-001` map route and UI layout work are not touched in this Backend commit.
