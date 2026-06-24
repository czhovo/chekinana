# Handoff

## From

Agent role: Backend

## Task ID

GEOM-BE-001

## Summary

Removed obsolete base-size polaroid geometry scaling and configured the current mini/wide output dimensions, image-area vertices, and white-balance sampling values directly.

## Files Changed

- `backend/app.py`
  - change: Removed `base_width`, `base_height`, `base_image_area_vertices`, runtime scale calculation, and the old base geometry constants from `POLAROID_GEOMETRIES`.
  - change: Directly configured mini `1200x1908` with image area `[[82,150],[1118,150],[1118,1533],[82,1533]]`.
  - change: Directly configured wide `2400x1908` with image area `[[82,150],[2318,150],[2318,1533],[82,1533]]`.
  - change: White-balance masking still uses the configured direct `image_area_vertices`; block scan size and step are now direct geometry values instead of scale-derived values.
- `scripts/check_polaroid_size.py`
  - change: Added assertions that mini/wide geometry no longer exposes base-size or scale fields, and that direct white-balance scan values remain `48` / `24`.
- `scripts/check_postprocessing_modes.py`
  - change: Updated the focused white-balance check fixture to use direct block size/step values.
- `docs/agents/handoffs/2026-06-23-geometry-mini.png`
  - change: Added visual confirmation artifact for mini output and image-area coordinates.
- `docs/agents/handoffs/2026-06-23-geometry-wide.png`
  - change: Added visual confirmation artifact for wide output and image-area coordinates.
- `docs/agents/handoffs/2026-06-23-backend-direct-polaroid-geometry.md`
  - change: Added this handoff.

## Behavior Changed

Runtime geometry is now expressed directly in current production coordinates. Mini/wide/auto size selection, output dimensions, result route behavior, status metadata, postprocessing modes, white balance behavior, auth, RunPod startup, task cancel, and upload cancel behavior are intended to remain compatible.

## API Contract Changes

None.

## Verification

Commands run:

```text
python -m py_compile backend/app.py scripts/check_polaroid_size.py scripts/check_postprocessing_modes.py
python scripts/check_polaroid_size.py
python scripts/check_postprocessing_modes.py
python -m py_compile scripts/check_large_result_routes.py
python scripts/check_large_result_routes.py
git diff --check
rg -n "\b800\b|\b1600\b|base_width|base_height|base_image_area|POLAROID_SCALE|BASE_POLAROID|BASE_IMAGE|\[\"scale\"\]|geometry\[\"scale\"\]" backend/app.py
```

Results:

```text
py_compile: passed
scripts/check_polaroid_size.py: passed
scripts/check_postprocessing_modes.py: passed
scripts/check_large_result_routes.py: passed
git diff --check: passed
backend/app.py obsolete geometry grep: no matches
visual artifact sizes: mini 1200x1908, wide 2400x1908
```

## Risks / Follow-up

- The first script run exposed that the default local Python environment was missing `opencv-python-headless`; I installed the project-required dependency and restored the environment to `numpy==1.23.5` with `opencv-python-headless==4.8.1.78` before rerunning checks.
- Reviewer should inspect the two PNG artifacts visually and compare them with the direct coordinates in `backend/app.py`.

## Notes For Next Agent

- PM assignment source: `c793b92 pm: assign direct geometry cleanup`.
- Visual artifacts:
  - `docs/agents/handoffs/2026-06-23-geometry-mini.png`
  - `docs/agents/handoffs/2026-06-23-geometry-wide.png`
