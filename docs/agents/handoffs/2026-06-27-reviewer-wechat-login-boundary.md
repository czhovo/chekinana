# Reviewer Handoff: WeChat Login Auth Boundary

## Findings

- P2 BLOCKING `wechat-miniprogram/pages/index/index.js:1727`
  `POST /api/contact` 的 Backend 合同已经在 `LOGIN-BE-002` 中改为不需要 scanner token，并且 taskboard 明确要求 contact flow 不应要求现有 backend/scanner token。但 Frontend 的 `sendContactMessage()` 仍然从 `AUTH_STORAGE_KEY` 读取 scanner token，缺少有效 token 或处于 local-preview token 时直接提示“请先使用有效 Token”并返回；随后请求头还通过 `this.getAuthHeader()` 给 `/api/contact` 附带 `X-Cheki-Token`。这会让只完成 WeChat 登录、没有 scanner token 的用户无法使用 contact flow，也使前后端本轮 auth boundary 不一致。
  Owner: Frontend

## Open Questions

- None.

## Verification

- Reviewed PM task `LOGIN-REV-002` from `a783c11`, Frontend commits `fbb351a` and `2de4a0e`, and Backend commits `ccb933b` and `f76c31c`.
- Read `docs/agents/README.md`, `docs/agents/worktree-workflow.md`, `docs/agents/prompts/reviewer.md`, `docs/agents/taskboard.md`, and the four Frontend/Backend LOGIN handoffs.
- Inspected `backend/app.py` route gate changes: `POST /api/auth/wechat-login` and `POST /api/auth/wechat-session/verify` are outside `requires_scanner_access_token()`, while scanner/extraction routes remain protected.
- Inspected Frontend login flow: `wechat-miniprogram/pages/auth/auth.js` posts `{ code }` to `https://api.chekinana.top/api/auth/wechat-login` with only `content-type: application/json`.
- Inspected Settings display: `wechat-miniprogram/pages/settings/settings.js` reads stored Backend session state and exposes only `userId`/expiry, not the Backend session token or WeChat identity fields.
- Inspected lianliankan warning fixes: `wx.getFileSystemManager().saveFile` is used and board loops retain `wx:key`.
- Ran `node --check wechat-miniprogram\pages\auth\auth.js`.
- Ran `node --check wechat-miniprogram\pages\settings\settings.js`.
- Ran `node --check wechat-miniprogram\pages\index\index.js`.
- Ran `node --check wechat-miniprogram\pages\lianliankan\lianliankan.js`.
- Ran `node --check wechat-miniprogram\utils\config.js`.
- Ran `node --check wechat-miniprogram\utils\lianliankan-assets.js`.
- Ran `python -m py_compile backend\app.py`.
- Ran `python -m py_compile scripts\check_wechat_login.py`.
- Ran `python scripts\check_wechat_login.py`; result: `wechat login checks passed`.
- Ran `git diff --check`.
- Ran public smoke checks: `https://api.chekinana.top/api/health` returned HTTP 401 from the current deployed service, and `https://chekinana.top/assets/lianliankan/v1/manifest.json` returned HTTP 200 JSON.
- Real WeChat `wx.login()` end-to-end testing was not performed because it requires production WeChat mini-program credentials and a fresh code.

## Verdict

changes requested
