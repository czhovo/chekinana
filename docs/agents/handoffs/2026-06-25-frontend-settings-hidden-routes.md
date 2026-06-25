# Handoff

## From

Agent role: Frontend

## Task ID

ROUTE-FE-001

## Summary

Moved the hidden `lianliankan` and `izaya7-map` entrances out of auth token input and into Settings buttons.

## Files Changed

- `wechat-miniprogram/pages/settings/settings.js`
  - change: Added `openLianliankan()` and `openIzaya7Map()` navigation handlers.
- `wechat-miniprogram/pages/settings/settings.wxml`
  - change: Added Settings buttons for `Lianliankan` and `izaya7's map`.
  - change: Replaced the previous placeholder copy with ASCII Settings copy.
- `wechat-miniprogram/pages/settings/settings.wxss`
  - change: Added a compact Settings button section and secondary button styling.
- `wechat-miniprogram/pages/auth/auth.js`
  - change: Removed exact-token special routes for `lianliankan` and `izaya7`; these strings now follow normal token validation.
- `wechat-miniprogram/app.json`
  - change: Preserved `pages/lianliankan/lianliankan` registration and top-level `"workers": "workers"`.
- `wechat-miniprogram/pages/lianliankan/`
  - change: Included the previously synced complete lianliankan page implementation and assets in this Frontend commit.
- `wechat-miniprogram/workers/`
  - change: Included lianliankan worker dependencies required by `wx.createWorker(...)`.
- `wechat-miniprogram/pages/izaya-map/`
  - change: Removed the old obsolete page directory from the Frontend worktree.

## Behavior Changed

Settings now owns the hidden page entries:

```text
Lianliankan -> /pages/lianliankan/lianliankan
izaya7's map -> /pages/izaya7-map/izaya7-map
```

Auth token input no longer contains hidden page-entry shortcuts. Exact inputs `lianliankan` and `izaya7` go through the normal backend token validation path and are not stored unless the backend validates them as real tokens.

## API Contract Changes

None. This is mini-program routing only. Backend `/api/auth/verify`, `/api/process`, status/result/cancel/upload-cancel/contact routes, RunPod startup, scanner lifecycle, picker, postprocessing, size-selection, and result handling contracts are unchanged.

## Verification

Commands run:

```text
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\settings\settings.js
node --check wechat-miniprogram\pages\lianliankan\lianliankan.js
node --check wechat-miniprogram\pages\lianliankan\board-generator.js
node --check wechat-miniprogram\pages\lianliankan\board-presets.js
node --check wechat-miniprogram\workers\lianliankan-generator.js
node --check wechat-miniprogram\workers\board-generator.js
node - <route behavior mock>
node - <app/json validation>
git diff --check
```

Mock checks covered:

```text
Settings button handlers navigate to the two hidden pages.
Auth input `lianliankan` does not navigate directly and sends normal token verification.
Auth input `izaya7` does not navigate directly and sends normal token verification.
Calendar shortcut remains unchanged.
```

## Risks / Follow-up

- Real-device QA should open Settings and confirm both buttons navigate correctly and that returning from the hidden pages restores normal tabBar behavior on tab pages.
