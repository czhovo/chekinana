# Handoff

## From

Agent role: Reviewer

## Task ID

GEOM-REV-001

## Findings

- None.

## Open Questions

- None.

## Verification

Reviewed commits:

```text
c793b92 pm: assign direct geometry cleanup
92036c4 backend: use direct polaroid geometry
```

Cherry-picked into reviewer worktree as:

```text
9b0e7f4 pm: assign direct geometry cleanup
03f8cf1 backend: use direct polaroid geometry
```

Commands run:

```text
python -m py_compile backend/app.py scripts/check_polaroid_size.py scripts/check_postprocessing_modes.py scripts/check_large_result_routes.py
python scripts/check_polaroid_size.py
python scripts/check_postprocessing_modes.py
python scripts/check_large_result_routes.py
git diff --check 48f00c3..HEAD
git diff --check
rg -n "\b800\b|\b1600\b|base_width|base_height|base_image_area|POLAROID_SCALE|BASE_POLAROID|BASE_IMAGE|\[\"scale\"\]|geometry\[\"scale\"\]" backend/app.py
file docs/agents/handoffs/2026-06-23-geometry-mini.png docs/agents/handoffs/2026-06-23-geometry-wide.png
python - <visual artifact pixel checks>
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
visual artifact pixel checks: passed
```

Reviewer confirmed:

- `backend/app.py` no longer keeps obsolete runtime geometry fields `base_width`, `base_height`, `base_image_area_vertices`, or `scale` in `POLAROID_GEOMETRIES`.
- Old geometry constants `BASE_POLAROID_W`, `BASE_POLAROID_H`, `POLAROID_SCALE`, and `BASE_IMAGE_AREA_VERTICES` were removed.
- Mini geometry is directly configured as `1200x1908` with image area `[[82,150],[1118,150],[1118,1533],[82,1533]]`.
- Wide geometry is directly configured as `2400x1908` with image area `[[82,150],[2318,150],[2318,1533],[82,1533]]`.
- White-balance border masking uses the direct configured `image_area_vertices`; block size and step are direct geometry values `48` / `24` rather than scale-derived values.
- Mini/wide/auto behavior remains intact: explicit mini and wide output the expected dimensions, and auto classifies vertical quadrilaterals as mini and horizontal quadrilaterals as wide.
- Postprocessing checks still pass, including fixed-border white balance with direct block/step values.
- Large-result route smoke still passes for 60 status entries, result ids `0`, `39`, `40`, `59`, and fresh `/api/process` upload.
- The mini and wide visual confirmation artifacts have the expected dimensions and visibly mark the configured image areas with coordinate labels.
- No reviewed diff changes auth, RunPod startup, task queue/cancel, upload cancel, result/status routes, Frontend API contracts, contact behavior, calendar routes, or `izaya7-map`.
- No old `pages/izaya-map` reference was reintroduced.

## Verdict

approved
