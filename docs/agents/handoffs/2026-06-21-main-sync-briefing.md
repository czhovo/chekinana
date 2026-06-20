# Main Sync Briefing: 2026-06-21

## Purpose

Every agent worktree has been updated with the current `origin/main` content. Before changing files touched by the main sync, read this briefing so new work does not accidentally undo the navigation, calendar, or map updates.

## Synced Baseline

- Integration worktree `C:\Users\20888\Desktop\chekinana` is on `main` at `d914343 Add mini program navigation tabs`.
- PM worktree received the sync through merge commit `36584a9`.
- Frontend worktree received the sync through merge commit `1a0fa48`.
- Backend worktree received the sync through merge commit `571513b`.
- Reviewer worktree received the sync through merge commit `04b1ff3`.

The main update range is `5e17549..d914343`.

## New Main Commits

- `16a3779 Add izaya7 map page`
- `aab9907 Add interactive izaya7 map records`
- `13e9f75 Merge izaya7 map page`
- `9c19e62 Add calendar mini program page`
- `b94ceb9 Merge branch 'codex/calendar-page'`
- `d914343 Add mini program navigation tabs`

## High-Level Changes

- Added a custom mini-program tab bar and navigation icons.
- Added a reusable `components/bottom-nav` component.
- Added `pages/calendar` with month navigation and date-grid UI.
- Added placeholder tab pages: `pages/idols`, `pages/gallery`, and `pages/settings`.
- Added the interactive `pages/izaya7-map` page and map data in `data/china-100000-full.js`.
- Removed the old `pages/izaya-map` page.
- Updated `app.json` page registration and tab bar configuration.
- Updated `pages/auth` routing shortcuts and copy.
- Updated `pages/index` so the scanner tab sets its selected tab state.
- Updated `utils/config.js` with navigation-related configuration.

Total surface from `5e17549..d914343`: 54 files changed, about 2469 insertions and 22 deletions.

## Frontend Notes

Current assigned task: `PICK-FE-001`.

Important context:

- The scanner page now participates in tab navigation. Do not remove `setTabBarSelected(0)` behavior in `pages/index/index.js`.
- `app.json` now owns more routes and the custom tab bar. Avoid reverting page registration or tab bar entries while fixing the image picker.
- `pages/auth/auth.js` now includes shortcuts to `izaya7-map` and calendar behavior. Preserve normal token auth and do not treat `izaya7` as a backend token.
- The old route `pages/izaya-map` is gone. Use `pages/izaya7-map`.
- The picker bug happens before upload and before `/api/process`. Keep the fix scoped to image selection and selected-image state normalization.
- Preserve these existing scanner contracts while changing picker code: max 9 images, add more after existing images, per-image count, rotation, `polaroid_size`, `postprocess_mode`, upload retry/cancel, completed navigation, all-download, and failed-source preservation.

Recommended checks:

```powershell
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\izaya7-map\izaya7-map.js
git diff --check
```

Targeted mocks should cover `wx.chooseImage`, user cancel, non-cancel failure, optional compatibility fallback, selected-image normalization, adding after existing images, and the 9-image limit.

## Backend Notes

There is no Backend implementation task for the image picker issue.

Why:

- The reported failure occurs after the user selects an album image but before the mini program adds it.
- That path fails before `wx.uploadFile`, before `/api/process`, and before any backend `task_id` exists.
- Backend upload, upload-cancel, task-cancel, RunPod startup, auth, result routes, postprocessing modes, and mini/wide/auto geometry are not part of this fix.

Backend should only get involved if PM explicitly reopens scope after Frontend finds a concrete upload contract blocker.

## Reviewer Notes

Current assigned task: `PICK-REV-001`.

Review expectations:

- Verify the picker fix is scoped to Frontend unless the diff proves otherwise.
- Verify user cancel is not shown as a failure.
- Verify non-cancel picker failures log the raw error and show a concise user-facing message.
- Verify selected paths from the chosen API are normalized into the existing selected-image model.
- Verify the fix does not regress scanner tab selection, custom tab bar config, `izaya7-map` routing, calendar route registration, batch upload/status/cancel behavior, or completed-result behavior.
- Read the Frontend handoff and this briefing before reviewing `app.json`, `pages/auth`, or `pages/index`.

Suggested checks:

```powershell
node --check wechat-miniprogram\pages\index\index.js
node --check wechat-miniprogram\pages\auth\auth.js
node --check wechat-miniprogram\pages\izaya7-map\izaya7-map.js
git diff --check
```

## Conflict Notes From Sync

During the main sync, conflicts were resolved toward `origin/main` for new route/tab/taskboard structure where needed:

- Frontend: `docs/agents/taskboard.md`, `wechat-miniprogram/app.json`, `wechat-miniprogram/pages/auth/auth.js`.
- Backend: `docs/agents/taskboard.md`.
- Reviewer: `wechat-miniprogram/app.json`, `wechat-miniprogram/pages/auth/auth.js`.

Do not reintroduce old `izaya-map` route references or old tab-free `app.json` structure.
