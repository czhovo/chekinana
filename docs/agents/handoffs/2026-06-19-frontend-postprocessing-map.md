# Handoff

## From

Agent role: Frontend

## Task ID

POST-FE-001

## Summary

Added the postprocessing mode selector, adjusted the count input layout, and added the `izaya7` map route from the auth page.

## Files Changed

- `wechat-miniprogram/pages/index/index.js`
  - change: Replaced boolean denoise page state with `postprocessMode`, defaulting to `denoise`.
  - change: Added `postprocess_mode=off|denoise|sharpen` to single-image and batch `/api/process` uploads while preserving legacy `denoise` compatibility.
- `wechat-miniprogram/pages/index/index.wxml`
  - change: Replaced the denoise switch with a three-option `关闭 / 降噪 / 锐化` selector placed to the right of the white-balance switch.
- `wechat-miniprogram/pages/index/index.wxss`
  - change: Added segmented selector styling consistent with the existing size selector.
  - change: Reduced the count input to a fixed narrow width and left empty space between the label and input.
- `wechat-miniprogram/pages/auth/auth.js`
  - change: Exact token input `izaya7` navigates to the map page without storing it or calling backend auth verification.
- `wechat-miniprogram/app.json`
  - change: Registered the new map page route.
- `wechat-miniprogram/pages/izaya-map/izaya-map.js`
  - change: Added blank page shell.
- `wechat-miniprogram/pages/izaya-map/izaya-map.json`
  - change: Set navigation title to `izaya7's map`.
- `wechat-miniprogram/pages/izaya-map/izaya-map.wxml`
  - change: Added an empty page view.
- `wechat-miniprogram/pages/izaya-map/izaya-map.wxss`
  - change: Added blank white page styling.
- `docs/agents/handoffs/2026-06-19-frontend-postprocessing-map.md`
  - change: Added this handoff.

## Behavior Changed

The main page now uses a postprocessing selector with labels `关闭`, `降噪`, and `锐化`; default mode is `降噪`, preserving the previous default behavior. Every upload now includes `postprocess_mode`, and still includes `denoise` for legacy backend compatibility:

```text
关闭 -> postprocess_mode=off, denoise=0
降噪 -> postprocess_mode=denoise, denoise=1
锐化 -> postprocess_mode=sharpen, denoise=1
```

Entering exactly `izaya7` on the auth page opens a blank page titled `izaya7's map` and does not store that value as a token or send it to `/api/auth/verify`.

## API Contract Changes

Frontend now submits `postprocess_mode=off|denoise|sharpen` with each existing `/api/process` upload. No routes, auth headers, result routes, status polling, upload cancel, task cancel, contact flow, `wb`, `rotation_degrees`, or `polaroid_size` contracts were otherwise changed.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\izaya-map\izaya-map.js
node - <mock script>
git diff --check
```

Results:

```text
node --check passed for changed JS files.
Mock checks passed: postprocess selector state, single-image and batch upload payload fields, legacy denoise compatibility, count-input layout markers, exact izaya7 route behavior, registered map page, and exact map navigation title.
git diff --check passed.
```

## Risks / Follow-up

- Backend `POST-BE-001` must implement `postprocess_mode` before `off` and `sharpen` affect output.
- Real-device UI QA should confirm the header controls remain comfortable on narrow phones after adding the three-option selector.

## Notes For Next Agent

- Invalid postprocessing modes normalize to `denoise`, matching the default behavior requirement.
- The `izaya7` route uses `wx.navigateTo` and intentionally does not write `AUTH_STORAGE_KEY`.
