# Handoff

## From

Agent role: Backend

## Task ID

RESULTDL-BE-001

## Summary

Reduced extracted polaroid output dimensions to 1200-width mini / 2400-width wide while preserving immediate incremental result availability through existing status and result routes.

## Files Changed

- `backend/app.py`
  - change: Updated `POLAROID_GEOMETRIES` so mini output is `1200x1908` and wide output is `2400x1908`.
  - change: Recomputed mini/wide image-area vertices from existing base border proportions at scale `1.5`.
  - change: Preserved existing per-polaroid `add_intermediate(...)` behavior inside the extraction loop, so each result is appended immediately after extraction.
- `scripts/check_polaroid_size.py`
  - change: Updated expected mini/wide dimensions, image-area vertices, and mini/wide/auto extraction output assertions.
- `scripts/check_large_result_routes.py`
  - change: Added focused smoke for 60 result metadata entries, result ids `0`, `39`, `40`, and `59`, plus fresh `/api/process` upload after high-count result downloads.
- `docs/agents/handoffs/2026-06-21-backend-large-result-downloads.md`
  - change: Added this handoff.

## Behavior Changed

Mini extracted output:

```text
width: 1200
height: 1908
image_area_vertices: [[82,150],[1118,150],[1118,1533],[82,1533]]
```

Wide extracted output:

```text
width: 2400
height: 1908
image_area_vertices: [[82,150],[2318,150],[2318,1533],[82,1533]]
```

Mini remains `1:1.59`. Wide remains equivalent to two mini outputs side by side. `auto`, `mini`, and `wide` request semantics are unchanged.

Immediate incremental availability is preserved: `do_process_extraction` still calls `add_intermediate(...)` inside the per-polaroid extraction loop before moving to the next detected quadrilateral and before task completion.

No intentional changes were made to RunPod startup, SAM detection, auth/token flow, frontend field names, postprocessing modes, upload cancel, task cancel, contact routes, result route shape, or production pod ID token flow.

## API Contract Changes

None.

Existing routes remain:

```text
GET /api/status/<task_id>
GET /api/result/<task_id>/<result_id>
POST /api/process
```

## Verification

Commands run:

```text
python -m py_compile backend\app.py scripts\check_polaroid_size.py scripts\check_postprocessing_modes.py scripts\check_large_result_routes.py
python scripts\check_polaroid_size.py
python scripts\check_large_result_routes.py
python scripts\check_postprocessing_modes.py
git diff --check
```

Results:

```text
py_compile: passed
scripts/check_polaroid_size.py: passed
- mini geometry is 1200x1908 with vertices [[82,150],[1118,150],[1118,1533],[82,1533]]
- wide geometry is 2400x1908 with vertices [[82,150],[2318,150],[2318,1533],[82,1533]]
- explicit mini, explicit wide, auto mini, and auto wide extraction output sizes passed
- missing/invalid polaroid_size fallback still passed
scripts/check_large_result_routes.py: passed
- /api/status/<task_id> exposed 60 result metadata entries
- /api/result/<task_id>/<result_id> served result ids 0, 39, 40, and 59
- a fresh /api/process upload returned 200 queued after high-count result downloads
scripts/check_postprocessing_modes.py: passed
git diff --check: passed
```

## Risks / Follow-up

- The output mask vertices are integer-rounded from the existing base proportions at scale `1.5`; the half-pixel ideal margins become symmetric integer masks after `np.rint`.
- Local scripts mock torch, flask-cors, and scipy.spatial so they can run without the full model/runtime stack on this workstation.
- Reviewer should verify real-device download behavior together with the Frontend immediate-download/retention changes.

## Notes For Next Agent

- Frontend should continue immediately downloading and displaying every returned result; Backend still exposes each result as soon as it is appended.
- This Backend change does not add a bundle/zip API and does not change result URLs.
