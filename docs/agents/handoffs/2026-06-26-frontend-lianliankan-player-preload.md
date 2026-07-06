# Frontend Handoff: Lianliankan Player Preload

## Task

Completed `LLPLAYER-FE-001` in the frontend worktree.

## Summary

- Replaced the lianliankan clear-state congratulations/replay text with a compact audio player.
- Added play/pause control, progress display, and a scrubbable progress slider for `muguang.m4a`.
- Preserved automatic playback after a board is cleared when the audio is ready.
- Kept pending download and failure states visible inside the player.
- Added mini-program startup tile-image cache warming through `App.onLaunch`.
- Kept image/audio assets remote; no package-local tile PNGs or `.m4a` files are bundled.

## Files Changed

- `wechat-miniprogram/app.js`
- `wechat-miniprogram/utils/lianliankan-assets.js`
- `wechat-miniprogram/pages/lianliankan/lianliankan.js`
- `wechat-miniprogram/pages/lianliankan/lianliankan.wxml`
- `wechat-miniprogram/pages/lianliankan/lianliankan.wxss`

## Behavior

- App startup calls `preloadLianliankanTileAssets()` and begins downloading the remote manifest/images without blocking normal startup.
- The lianliankan page reuses the same tile-asset preload/cache helper, so page entry can reuse startup-warmed assets.
- When a board clears:
  - old `恭喜过关` / `再来一局` UI is not rendered,
  - the player is shown,
  - ready audio starts once automatically,
  - pending audio shows `音效下载中...`,
  - failed audio shows `音效下载失败`.
- Player control supports pause/resume and seeking through the slider.
- Reset/new game/hide/unload stop playback and reset player state without duplicate autoplay.

## Verification

- `node --check wechat-miniprogram\app.js`
- `node --check wechat-miniprogram\utils\lianliankan-assets.js`
- `node --check wechat-miniprogram\pages\lianliankan\lianliankan.js`
- `git diff --check`
- Verified `wechat-miniprogram/pages/lianliankan/images` does not exist.
- Verified no `.m4a` files exist under `wechat-miniprogram`.
- Targeted Node mock verified:
  - `App.onLaunch` starts manifest download for tile preload,
  - clear-state player autoplays ready audio once,
  - play/pause toggles correctly,
  - time updates keep progress labels in sync,
  - slider seeking calls `InnerAudioContext.seek`,
  - stop/destroy clears playing state.

## Notes For Reviewer

- Backend is intentionally unchanged for this round.
- Public asset delivery still depends on `https://chekinana.top/assets/lianliankan/v1/...` remaining available as a WeChat `downloadFile` legal domain.
