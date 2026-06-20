# Handoff

## From

Agent role: Frontend

## Task ID

SIZE-FE-001

## Summary

Added a per-image `auto / mini / wide` polaroid size selector in the input preview and submit the selected value as `polaroid_size` with each `/api/process` upload.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Added per-image `polaroidSize` state with `mini` default, current-image synchronization, validation fallback, and upload form fields for single and sequential batch processing.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Added a three-option size selector inside the preview frame near the upper-right corner.
- `wechat-miniprogram/pages/index/index.wxss`
  - change: Added stable segmented-control styling for the preview size selector.
- `docs/agents/handoffs/2026-06-18-frontend-polaroid-size.md`
  - change: Added this handoff.

## Behavior Changed

Every newly selected image now starts with `mini` as its polaroid size. Users can switch the current image between `auto`, `mini`, and `wide`; the choice is stored on that image and follows thumbnail/arrow navigation, rotation, deletion, and batch processing. Each single-image or per-image batch upload now includes `polaroid_size` alongside the existing token, white-balance, denoise, rotation, upload attempt id, and optional expected-count fields.

## API Contract Changes

Frontend now sends existing `/api/process` requests with multipart form field:

```text
polaroid_size=auto|mini|wide
```

No route, auth, result, status, cancel, upload-cancel, contact, or download contract changed.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node - <mock script>
git diff --check
```

Results:

```text
node --check passed.
Mock checks passed: default mini, per-image independent size state, selector placement/state, single-image upload field, batch per-image upload fields, and count/rotation compatibility.
git diff --check passed.
```

## Risks / Follow-up

- Backend must implement `polaroid_size` handling in `SIZE-BE-001` before `auto` and `wide` affect extraction output.
- Real-device visual QA should confirm the overlay selector does not cover important image content on very small screens.

## Notes For Next Agent

- Missing or invalid `polaroidSize` values are normalized to `mini` before upload, matching the taskboard fallback contract.
- The selector uses `catchtap` so tapping size options does not trigger the preview-frame delete action.
