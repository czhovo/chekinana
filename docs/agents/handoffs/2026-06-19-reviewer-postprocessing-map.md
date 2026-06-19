# Handoff

## From

Agent role: Reviewer

## Task ID

POST-REV-001

## Findings

- None.

## Open Questions

- None.

## Verification

Reviewed commits:

```text
f369772 docs: assign postprocessing map tasks
9706534 docs: add linear rgb white balance requirement
cf36d6c frontend: add postprocessing selector and map route
c3bc24f Add backend postprocessing modes
```

Commands run:

```text
node --check wechat-miniprogram/pages/index/index.js
node --check wechat-miniprogram/pages/auth/auth.js
node --check wechat-miniprogram/pages/izaya-map/izaya-map.js
python -m py_compile backend/app.py scripts/check_postprocessing_modes.py scripts/check_polaroid_size.py
git diff --check 011e42e..HEAD
python scripts/check_postprocessing_modes.py
python scripts/check_polaroid_size.py
node - <frontend postprocessing/map mock>
```

Results:

```text
node --check: passed
py_compile: passed
git diff --check: passed
scripts/check_postprocessing_modes.py: passed
scripts/check_polaroid_size.py: passed
frontend postprocessing/map checks passed
```

Reviewer confirmed:

- Frontend replaces the old denoise switch with exactly `关闭 / 降噪 / 锐化`, defaults to `denoise`, and places the selector next to the white-balance switch.
- Single-image and batch uploads both send `postprocess_mode=off|denoise|sharpen` while preserving legacy `denoise`, `wb`, `rotation_degrees`, and per-image `polaroid_size`.
- The count input is narrowed and separated from the `图片n/m包含的拍立得数量` label.
- Exact auth-page input `izaya7` navigates to `/pages/izaya-map/izaya-map`, whose navigation title is `izaya7's map`; it is not stored and does not call `/api/auth/verify`.
- Normal token auth still calls `/api/auth/verify` and keeps the existing backend-token path.
- Backend accepts `postprocess_mode=off|denoise|sharpen`; missing or invalid values fall back to `denoise`, and absent `postprocess_mode` still honors legacy `denoise=0/1`.
- `off` skips denoise/sharpen while preserving optional white balance.
- White balance now operates in `linear_rgb` and reports `white_balance_color_space` metadata.
- `denoise` uses LAB-channel OpenCV NLM with L `h=3.5`, A/B `h=6.0`, template `7`, search `21`.
- `sharpen` runs denoise first, then LAB L-channel USM with `sigma=1.0`, `amount=0.45`, `threshold=3.0`, leaving A/B channels unchanged.
- Existing mini/wide/auto geometry checks still pass.
- No reviewed diff changes RunPod startup, auth route contracts, task/result/cancel routes, contact route, or SAM detection.

## Verdict

approved
