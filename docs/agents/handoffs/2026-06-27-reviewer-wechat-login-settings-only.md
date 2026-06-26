# Reviewer Handoff: WeChat Login Settings Only

## Findings

- P1 BLOCKING `cloudflare-worker/src/worker.js:58`
  用户在 Settings 点击微信登录后仍看到“Token 无效或已过期”的原因不是 `LOGIN-FE-003` 的按钮绑定仍指向 scanner-token 验证；当前 `settings.wxml` 已绑定 `loginWithWeChat`，`settings.js` 也只向 `POST https://api.chekinana.top/api/auth/wechat-login` 发送 `{ code }` 和 `content-type: application/json`。真正的阻断点在 `api.chekinana.top/*` 的 Cloudflare Worker：它在转发任何请求前都从 `X-Cheki-Token` 或 `?token=` 解析 pod id，缺少 token 就直接返回 `{"ok":false,"error":"Token 无效或已过期"}`，没有为 `/api/auth/wechat-login`、`/api/auth/wechat-session/verify` 或 `/api/contact` 提供无 scanner-token 例外。生产 smoke 复现了同样响应，所以 Settings 微信登录和 contact 的无 scanner-token 合同仍无法在线上通过。
  Owner: Backend/PM to assign API Worker boundary fix

## Open Questions

- None.

## Verification

- Reviewed PM task `LOGIN-REV-003` from `683d485` and Frontend commit `6cbe7c7`.
- Read `docs/agents/prompts/reviewer.md`, `docs/agents/taskboard.md`, and `docs/agents/handoffs/2026-06-27-frontend-wechat-login-settings-only.md`.
- Inspected `wechat-miniprogram/pages/settings/settings.wxml`: the Settings WeChat button binds to `loginWithWeChat`.
- Inspected `wechat-miniprogram/pages/settings/settings.js`: Settings calls `wx.login()` and posts `{ code }` to `https://api.chekinana.top/api/auth/wechat-login` without `X-Cheki-Token`.
- Inspected `wechat-miniprogram/pages/auth/auth.js`: WeChat login state, `wx.login()`, and session storage side effects were removed from the scanner-token auth page.
- Inspected `wechat-miniprogram/pages/index/index.js`: `/api/contact` now posts to `https://api.chekinana.top/api/contact` with only `content-type: application/json`, not `getAuthHeader()`.
- Inspected `cloudflare-worker/src/worker.js`: the Worker still requires a token-derived RunPod pod id before forwarding all non-OPTIONS requests.
- Ran `node --check wechat-miniprogram\pages\auth\auth.js`.
- Ran `node --check wechat-miniprogram\pages\settings\settings.js`.
- Ran `node --check wechat-miniprogram\pages\index\index.js`.
- Ran `node --check wechat-miniprogram\utils\config.js`.
- Ran `node --check cloudflare-worker\src\worker.js`.
- Ran `python -m py_compile backend\app.py`.
- Ran `python scripts\check_wechat_login.py`; result: `wechat login checks passed`.
- Ran `git diff --check`.
- Search confirmed `wx.login`, `wechat-login`, and `USER_SESSION_STORAGE_KEY` appear in Settings and not in `pages/auth`.
- Production smoke checks without `X-Cheki-Token`:
  - `POST https://api.chekinana.top/api/auth/wechat-login` returned HTTP 401 `{"ok":false,"error":"Token 无效或已过期"}`.
  - `POST https://api.chekinana.top/api/auth/wechat-session/verify` returned HTTP 401 `{"ok":false,"error":"Token 无效或已过期"}`.
  - `POST https://api.chekinana.top/api/contact` returned HTTP 401 `{"ok":false,"error":"Token 无效或已过期"}`.
  - `https://chekinana.top/assets/lianliankan/v1/manifest.json` still returned HTTP 200 JSON.
- Real WeChat credential testing was not completed because the production API Worker blocks the login request before it can reach the Flask WeChat login endpoint.

## Verdict

changes requested
