# Handoff

## From

Agent role: Backend

## Task ID

SIZE-BE-001

## Summary

Added Backend mini/wide/auto polaroid output-size support while preserving the existing mini default behavior.

## Files Changed

- `backend/app.py`
  - change: Added explicit size constants and `POLAROID_GEOMETRIES` for `mini` and `wide`.
  - change: Added `parse_polaroid_size`, `get_polaroid_geometry`, `quad_horizontal_vertical_ratio`, and `resolve_polaroid_size`.
  - change: `/api/process` now accepts multipart form field `polaroid_size` with values `auto`, `mini`, or `wide`; missing or invalid values fall back to `mini`.
  - change: Extraction now resolves output geometry per detected quadrilateral and passes the selected geometry into fixed-border white balance.
- `scripts/check_polaroid_size.py`
  - change: Added mocked local checks for size parsing, geometry constants, auto classification, extraction output dimensions, and request fallback behavior.
- `docs/agents/handoffs/2026-06-18-backend-polaroid-size.md`
  - change: Added this handoff.

## Behavior Changed

Default behavior remains `mini`, matching the old output size and mask geometry.

`mini` geometry:
- Base card: `800x1272`
- Output: `1600x2544`
- Image-area vertices: `[[110,200],[1490,200],[1490,2044],[110,2044]]`

`wide` geometry:
- Base card: `1600x1272`
- Output: `3200x2544`
- Image-area vertices: `[[110,200],[3090,200],[3090,2044],[110,2044]]`

If `polaroid_size=mini`, every detected quadrilateral is warped/exported as mini.

If `polaroid_size=wide`, every detected quadrilateral is warped/exported as wide.

If `polaroid_size=auto`, each detected quadrilateral is classified independently by `avg(horizontal edge lengths) / avg(vertical edge lengths)`: ratio `> 1` resolves to `wide`; ratio `<= 1` resolves to `mini`.

Detection, count retry/pruning, denoise, rotation, task queue/cancel, auth, RunPod startup, result routes, and existing status/result compatibility were not intentionally changed. Fixed-border white balance now receives the selected geometry so wide output uses the wide image-area mask.

## API Contract Changes

`POST /api/process` accepts an optional multipart form field:

```text
polaroid_size=auto|mini|wide
```

Missing or invalid values fall back safely to `mini`. Existing response shapes are preserved; the normalized value is stored server-side for processing but is not added to status/result responses.

## Verification

Commands run:

```text
python -m py_compile backend\app.py scripts\check_polaroid_size.py
python scripts\check_polaroid_size.py
git diff --check
```

Results:

```text
py_compile passed.
scripts/check_polaroid_size.py passed:
- mini geometry output size 1600x2544 and vertices [[110,200],[1490,200],[1490,2044],[110,2044]]
- wide geometry output size 3200x2544 and vertices [[110,200],[3090,200],[3090,2044],[110,2044]]
- explicit mini forces mini output even for wide-shaped quadrilateral
- explicit wide forces wide output even for mini-shaped quadrilateral
- auto classifies mini-shaped quadrilateral as mini
- auto classifies wide-shaped quadrilateral as wide
- missing polaroid_size in /api/process falls back to mini
- invalid polaroid_size in /api/process falls back to mini
git diff --check passed.
```

## Risks / Follow-up

- The local size check mocks SAM3, torch, flask-cors, and scipy because this workstation does not have the heavy model/runtime stack installed and its SciPy/Numpy versions are incompatible. The test still runs the real Backend extraction function with mocked detection candidates and verifies the generated PNG dimensions.
- Frontend must send `polaroid_size` per image as planned by `SIZE-FE-001`.

## Notes For Next Agent

- Reviewer should re-run `python -m py_compile backend/app.py`, `python scripts/check_polaroid_size.py`, and `git diff --check`.
- No stricter validation was added; fallback-to-mini is the documented behavior.
