# 微博抽奖工具一次性下载门禁

这个独立 Cloudflare Worker 只负责两件事：通过 Cloudflare Access 保护的管理页生成一次性 token，以及在 token 首次被正确提交时返回已签名的 `weibo-lottery-v3.shortcut`。新下载 token 固定为 6 位 `0-9A-Z` 组合，使用无模偏差的加密随机拒绝采样；提交时不区分大小写，服务端先统一为大写，再校验、哈希和核销。消费路径仍识别旧版 43 位 base64url token，并严格按原值哈希；旧格式不会再被生成或展示。

Durable Object 只保存一个 active token 的 SHA-256。任何时刻全局最多一个下载 token 有效：未使用时永久有效，再次生成会在事务中原子替换 active hash 并立即使旧码失效，成功消费会原子删除 active hash。旧部署遗留的多个 `token:<hash>` 存储键会被忽略，因此部署此单例格式时，所有仍依赖旧存储键的未使用 token 会失效；这些旧键不会被消费，也不会影响新的单例状态。管理表单的 CSRF token 与下载 token 相互独立，仍使用 32 字节随机值。

## 本地验证

```sh
npm install
npm test
node --check src/worker.js
```

## 部署准备

1. 在 Cloudflare Zero Trust 中为 `/tools/weibo-lottery/admin*` 创建 Access Self-hosted 应用，只允许管理员身份访问。
2. 从 Access 应用取得 Application Audience (AUD)，从 Zero Trust 设置取得 team domain。不要把真实值写入仓库。
3. 将两项配置以 Worker secret 注入：

```sh
npx wrangler secret put TEAM_DOMAIN
npx wrangler secret put POLICY_AUD
```

`TEAM_DOMAIN` 可填写 `your-team.cloudflareaccess.com` 或对应的 HTTPS origin；`POLICY_AUD` 填 Access 应用的 AUD。Worker 会使用 Cloudflare Access 的远程 JWKS 再次校验 `Cf-Access-Jwt-Assertion`。

## 部署顺序

1. 确认 `assets/weibo-lottery-v3.shortcut` 是最新且已经签名的安装文件。
2. 配置 Access 应用及仅管理员可通过的策略。
3. 注入 `TEAM_DOMAIN`、`POLICY_AUD`。
4. 运行 `npx wrangler deploy`。
5. 最后发布安装页；安装页会通过同源 POST 请求 `/tools/weibo-lottery/api/download`，不会包含公开的 iCloud 链接或快捷指令直链。

不要为静态资产增加公开 route。`run_worker_first = true` 确保所有已配置 route 先经过 Worker。对于格式正确的下载请求，Worker 会先通过 `ASSETS` binding 读取并完整缓冲快捷指令；只有 asset 读取成功后才原子核销 active token 并返回文件，从而避免 asset 读取失败时烧掉仍然有效的 token。由于 asset 读取发生在核销之前，无效但格式正确的 token 请求也可能先触发一次 asset 读取，但不会获得文件。
